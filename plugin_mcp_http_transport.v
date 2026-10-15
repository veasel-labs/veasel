module main

import mcp
import json2
import net.http
import time

const max_plugin_mcp_http_body_bytes = 1_000_000
const max_plugin_mcp_http_messages = 64
const plugin_mcp_http_response_timeout = 20 * time.second
const plugin_mcp_http_notification_timeout = 2 * time.second
const plugin_mcp_http_close_timeout = 250 * time.millisecond

// PluginMCPHTTPTransport adapts bounded Streamable HTTP requests to the
// MCP client transport interface. Redirects and automatic retries are disabled
// because configured plugin headers are bound to the configured origin and a
// retried tools/call request could repeat side effects. A single OAuth refresh
// retry on HTTP 401 is allowed when a named credential with refresh metadata
// is attached (expired Bearer only; not a general retry policy).
@[heap]
struct PluginMCPHTTPTransport {
mut:
	url                                string
	headers                            map[string]string
	credential                         string
	oauth_refresh                      &MCPOAuthRefreshState = unsafe { nil }
	mcp_credentials                    &MCPCredentialState   = unsafe { nil }
	session_id                         string
	protocol_version                   string
	pending                            []string
	notifications                      []string
	cancel_requested                   bool
	active_request_id                  string
	cancelled_notified                 bool
	last_auth_challenge                MCPAuthChallenge
	has_auth_challenge                 bool
	last_resource_metadata             MCPProtectedResourceMetadata
	has_resource_metadata              bool
	last_authorization_server_metadata MCPAuthorizationServerMetadata
	has_authorization_server_metadata  bool
}

fn new_plugin_mcp_http_transport(server PluginMCPServer) !&PluginMCPHTTPTransport {
	if server.transport != 'streamable-http' || server.url.len == 0 {
		return error('unsupported Agent Plugin MCP HTTP server')
	}
	return &PluginMCPHTTPTransport{
		url:        server.url
		headers:    server.headers.clone()
		credential: server.credential
	}
}

// attach_oauth_refresh wires owner-only refresh + credential stores so a 401
// can exchange a stored refresh token once and retry the same request.
fn (mut transport PluginMCPHTTPTransport) attach_oauth_refresh(credential string, refresh &MCPOAuthRefreshState,
	credentials &MCPCredentialState) {
	if credential.len == 0 || isnil(refresh) || isnil(credentials) {
		return
	}
	if !is_valid_mcp_credential_name(credential) {
		return
	}
	transport.credential = credential
	transport.oauth_refresh = refresh
	transport.mcp_credentials = credentials
}

fn (mut transport PluginMCPHTTPTransport) try_refresh_oauth_credential() bool {
	if transport.credential.len == 0 || isnil(transport.oauth_refresh)
		|| isnil(transport.mcp_credentials) {
		return false
	}
	mut refresh := transport.oauth_refresh
	if !refresh.has(transport.credential) {
		return false
	}
	mut credentials := transport.mcp_credentials
	_ := refresh_mcp_oauth_credential(mut refresh, mut credentials, transport.credential) or {
		return false
	}
	cred_headers := credentials.get_headers(transport.credential) or { return false }
	auth := cred_headers['Authorization'] or { return false }
	if auth.len == 0 {
		return false
	}
	mut next := map[string]string{}
	for key, value in transport.headers {
		if key.to_lower() == 'authorization' {
			continue
		}
		next[key] = value
	}
	next['Authorization'] = auth
	transport.headers = next
	return true
}

fn (mut transport PluginMCPHTTPTransport) request_cancel() {
	transport.cancel_requested = true
}

fn (mut transport PluginMCPHTTPTransport) record_http_auth_challenge(www_authenticate string) {
	transport.has_auth_challenge = false
	transport.has_resource_metadata = false
	transport.has_authorization_server_metadata = false
	transport.last_auth_challenge = MCPAuthChallenge{}
	transport.last_resource_metadata = MCPProtectedResourceMetadata{}
	transport.last_authorization_server_metadata = MCPAuthorizationServerMetadata{}
	challenge := parse_www_authenticate_bearer(www_authenticate) or { return }
	transport.last_auth_challenge = challenge
	transport.has_auth_challenge = true
	if challenge.resource_metadata.len == 0 {
		return
	}
	// Best-effort RFC 9728 + RFC 8414 discovery. Never forwards MCP headers.
	metadata := fetch_mcp_protected_resource_metadata(challenge.resource_metadata) or { return }
	transport.last_resource_metadata = metadata
	transport.has_resource_metadata = true
	if metadata.authorization_servers.len == 0 {
		return
	}
	as_metadata := fetch_mcp_authorization_server_metadata(metadata.authorization_servers[0]) or {
		return
	}
	transport.last_authorization_server_metadata = as_metadata
	transport.has_authorization_server_metadata = true
}

fn (transport &PluginMCPHTTPTransport) authorization_required_error() string {
	if !transport.has_auth_challenge {
		return 'MCP HTTP authorization required'
	}
	mut detail := mcp_auth_challenge_summary(transport.last_auth_challenge)
	if transport.has_resource_metadata {
		meta := mcp_protected_resource_metadata_summary(transport.last_resource_metadata)
		if meta.len > 0 {
			detail += '; ${meta}'
		}
	}
	if transport.has_authorization_server_metadata {
		as_meta := mcp_authorization_server_metadata_summary(transport.last_authorization_server_metadata)
		if as_meta.len > 0 {
			detail += '; ${as_meta}'
		}
	}
	return 'MCP HTTP authorization required (${detail})'
}

fn (mut transport PluginMCPHTTPTransport) emit_cancelled_notification() {
	if transport.cancelled_notified || transport.active_request_id.len == 0 {
		return
	}
	transport.cancelled_notified = true
	notification := plugin_mcp_cancelled_notification(transport.active_request_id, 'turn cancelled')
	if notification.len == 0 || notification.len > max_plugin_mcp_http_body_bytes {
		return
	}
	mut header := http.new_header()
	header.add_custom_map(plugin_mcp_http_user_headers(transport.headers)) or { return }
	header.set(.content_type, 'application/json')
	header.set(.accept, 'application/json, text/event-stream')
	if transport.session_id.len > 0 {
		header.set_custom('MCP-Session-Id', transport.session_id) or { return }
	}
	if transport.protocol_version.len > 0 {
		header.set_custom('MCP-Protocol-Version', transport.protocol_version) or { return }
	}
	_ := http.fetch(
		url:                  transport.url
		method:               .post
		data:                 notification
		header:               header
		validate:             transport.url.starts_with('https://')
		allow_redirect:       false
		max_retries:          1
		read_timeout:         plugin_mcp_http_close_timeout
		write_timeout:        plugin_mcp_http_close_timeout
		stop_copying_limit:   max_plugin_mcp_http_body_bytes + 1
		stop_receiving_limit: max_plugin_mcp_http_body_bytes + 1
	) or { return }
}

fn (mut transport PluginMCPHTTPTransport) send(message string) ! {
	return transport.send_with_auth_refresh(message, true)
}

fn (mut transport PluginMCPHTTPTransport) send_with_auth_refresh(message string, allow_auth_refresh bool) ! {
	if message.len == 0 || message.len > max_plugin_mcp_http_body_bytes {
		return error('MCP HTTP request exceeds the message size limit')
	}
	request_id := plugin_mcp_jsonrpc_request_id_json(message)
	if request_id.len > 0 {
		transport.active_request_id = request_id
		transport.cancelled_notified = false
	}
	if transport.cancel_requested {
		transport.emit_cancelled_notification()
		return error('cancelled')
	}
	mut header := http.new_header()
	header.add_custom_map(plugin_mcp_http_user_headers(transport.headers))!
	header.set(.content_type, 'application/json')
	header.set(.accept, 'application/json, text/event-stream')
	if transport.session_id.len > 0 {
		header.set_custom('MCP-Session-Id', transport.session_id)!
	}
	if transport.protocol_version.len > 0 {
		header.set_custom('MCP-Protocol-Version', transport.protocol_version)!
	}
	stateless_version, request_method, request_name := plugin_mcp_http_request_headers(message)
	if stateless_version.len > 0 {
		header.set_custom('MCP-Protocol-Version', stateless_version)!
		header.set_custom('Mcp-Method', request_method)!
		if request_name.len > 0 {
			header.set_custom('Mcp-Name', request_name)!
		}
	}
	// Re-check after header assembly so a cancel that arrives while preparing
	// the request never opens a socket. Once fetch starts, cancel is observed
	// on the first net.http progress callback (status/header bytes count);
	// true TTFB-before-any-progress abort is a hard limit — see
	// docs/compatibility/http-cancel-limits.md.
	if transport.cancel_requested {
		transport.emit_cancelled_notification()
		return error('cancelled')
	}
	response := http.fetch(
		url:                  transport.url
		method:               .post
		data:                 message
		header:               header
		validate:             transport.url.starts_with('https://')
		allow_redirect:       false
		max_retries:          1
		read_timeout:         plugin_mcp_http_response_timeout
		write_timeout:        plugin_mcp_http_response_timeout
		stop_copying_limit:   max_plugin_mcp_http_body_bytes + 1
		stop_receiving_limit: max_plugin_mcp_http_body_bytes + 1
		on_progress:          fn [mut transport] (_ &http.Request, _ []u8, _ u64) ! {
			if transport.cancel_requested {
				return error('cancelled')
			}
		}
		on_progress_body:     fn [mut transport] (_ &http.Request, _ []u8, _ u64, _ u64, _ int) ! {
			if transport.cancel_requested {
				return error('cancelled')
			}
		}
	) or {
		if err.msg() == 'cancelled' || transport.cancel_requested {
			transport.emit_cancelled_notification()
			return error('cancelled')
		}
		return error(err.msg())
	}
	// Best-effort: if cancel arrived while net.http finished assembling the
	// response (after the last progress callback), do not deliver pending RPC.
	// True TTFB-before-any-progress abort remains a net.http hard limit; see
	// docs/compatibility/http-cancel-limits.md.
	if transport.cancel_requested {
		transport.emit_cancelled_notification()
		return error('cancelled')
	}
	if response.status_code in 300 .. 400 {
		return error('MCP HTTP redirects are disabled to protect configured headers')
	}
	if response.status_code == 401 {
		www_authenticate := response.header.get(.www_authenticate) or { '' }
		transport.record_http_auth_challenge(www_authenticate)
		transport.pending.clear()
		if allow_auth_refresh && transport.try_refresh_oauth_credential() {
			return transport.send_with_auth_refresh(message, false)
		}
		return error(transport.authorization_required_error())
	}
	if response.body.len > max_plugin_mcp_http_body_bytes {
		return error('MCP HTTP response exceeds the message size limit')
	}
	if stateless_version.len == 0 {
		if session_id := response.header.get_custom('MCP-Session-Id') {
			if !valid_plugin_mcp_http_header_value(session_id) || session_id.len > 1024 {
				return error('MCP HTTP server returned an invalid session id')
			}
			transport.session_id = session_id
		}
		if version := response.header.get_custom('MCP-Protocol-Version') {
			if !valid_plugin_mcp_http_header_value(version) || version.len > 128 {
				return error('MCP HTTP server returned an invalid protocol version')
			}
			transport.protocol_version = version
		}
	}
	if response.status_code == 202 && response.body.trim_space().len == 0 {
		return
	}
	content_type := response.header.get(.content_type) or {
		return error('MCP HTTP response omitted its content type')
	}
	media_type := content_type.all_before(';').trim_space().to_lower()
	mut response_messages := []string{}
	match media_type {
		'application/json' {
			if response.body.trim_space().len == 0 {
				return error('MCP HTTP server returned an empty JSON response (status ${response.status_code})')
			}
			response_messages << response.body
		}
		'text/event-stream' {
			response_messages = parse_plugin_mcp_http_sse(response.body)!
		}
		else {
			return error('MCP HTTP response used an unsupported content type')
		}
	}
	if stateless_version.len == 0 && transport.protocol_version.len == 0 {
		for response_message in response_messages {
			version := plugin_mcp_http_protocol_version(response_message)
			if version.len > 0 {
				transport.protocol_version = version
				break
			}
		}
	}
	transport.pending << response_messages
	if transport.pending.len > max_plugin_mcp_http_messages {
		transport.pending.clear()
		return error('MCP HTTP response exceeded the message count limit')
	}
	if response.status_code < 200 || response.status_code >= 300 {
		// Preserve JSON-RPC protocol errors (notably UnsupportedProtocolVersion)
		// so vlib/mcp can perform its specified downgrade and retry.
		if response_messages.len > 0 && response_messages.all(plugin_mcp_http_has_jsonrpc_error(it)) {
			return
		}
		transport.pending.clear()
		return error('MCP HTTP server returned status ${response.status_code} without a JSON-RPC error')
	}
}

fn (mut transport PluginMCPHTTPTransport) receive() !string {
	if transport.cancel_requested {
		transport.emit_cancelled_notification()
		return error('cancelled')
	}
	if transport.pending.len == 0 {
		return error('MCP HTTP response did not contain an MCP message')
	}
	message := transport.pending[0]
	transport.pending = if transport.pending.len == 1 {
		[]string{}
	} else {
		transport.pending[1..].clone()
	}
	return message
}

// listen_notifications opens the Streamable HTTP GET notification stream and
// appends completed SSE `message` events to the notifications queue (never the
// RPC pending queue). Long-lived streams abort when cancel is requested via
// on_progress_body. Servers that answer 405/404 are treated as not offering a
// notification stream.
fn (mut transport PluginMCPHTTPTransport) listen_notifications() !int {
	return transport.listen_notifications_with_auth_refresh(true)
}

fn (mut transport PluginMCPHTTPTransport) listen_notifications_with_auth_refresh(allow_auth_refresh bool) !int {
	if transport.cancel_requested {
		return error('cancelled')
	}
	mut header := http.new_header()
	header.add_custom_map(plugin_mcp_http_user_headers(transport.headers))!
	header.set(.accept, 'text/event-stream')
	if transport.session_id.len > 0 {
		header.set_custom('MCP-Session-Id', transport.session_id)!
	}
	if transport.protocol_version.len > 0 {
		header.set_custom('MCP-Protocol-Version', transport.protocol_version)!
	}
	if transport.cancel_requested {
		return error('cancelled')
	}
	mut stream := &PluginMCPHTTPSseStream{}
	before := transport.notifications.len
	response := http.fetch(
		url:                  transport.url
		method:               .get
		header:               header
		validate:             transport.url.starts_with('https://')
		allow_redirect:       false
		max_retries:          1
		read_timeout:         plugin_mcp_http_notification_timeout
		write_timeout:        plugin_mcp_http_notification_timeout
		stop_copying_limit:   max_plugin_mcp_http_body_bytes + 1
		stop_receiving_limit: max_plugin_mcp_http_body_bytes + 1
		on_progress:          fn [mut transport] (_ &http.Request, _ []u8, _ u64) ! {
			if transport.cancel_requested {
				return error('cancelled')
			}
		}
		on_progress_body:     fn [mut transport, mut stream] (_ &http.Request, chunk []u8, _ u64, _ u64, _ int) ! {
			if transport.cancel_requested {
				return error('cancelled')
			}
			messages := stream.feed(chunk)!
			for message in messages {
				transport.append_notification(message)!
			}
		}
	) or {
		if err.msg() == 'cancelled' || transport.cancel_requested {
			return error('cancelled')
		}
		return error(err.msg())
	}
	if transport.cancel_requested {
		return error('cancelled')
	}
	if response.status_code in [404, 405] {
		return 0
	}
	if response.status_code == 401 {
		www_authenticate := response.header.get(.www_authenticate) or { '' }
		transport.record_http_auth_challenge(www_authenticate)
		if allow_auth_refresh && transport.try_refresh_oauth_credential() {
			return transport.listen_notifications_with_auth_refresh(false)
		}
		return error(transport.authorization_required_error())
	}
	if response.status_code in 300 .. 400 {
		return error('MCP HTTP redirects are disabled to protect configured headers')
	}
	if response.status_code < 200 || response.status_code >= 300 {
		return error('MCP HTTP notification stream returned status ${response.status_code}')
	}
	content_type := response.header.get(.content_type) or { 'text/event-stream' }
	media_type := content_type.all_before(';').trim_space().to_lower()
	if media_type.len > 0 && media_type != 'text/event-stream' {
		return error('MCP HTTP notification stream used an unsupported content type')
	}
	tail := stream.finish()!
	for message in tail {
		transport.append_notification(message)!
	}
	return transport.notifications.len - before
}

fn (mut transport PluginMCPHTTPTransport) append_notification(message string) ! {
	if message.len == 0 {
		return
	}
	if transport.notifications.len >= max_plugin_mcp_http_messages {
		return error('MCP HTTP SSE response exceeded the message count limit')
	}
	transport.notifications << message
}

fn (mut transport PluginMCPHTTPTransport) receive_notification() !string {
	if transport.notifications.len == 0 {
		return error('MCP HTTP notification queue is empty')
	}
	message := transport.notifications[0]
	transport.notifications = if transport.notifications.len == 1 {
		[]string{}
	} else {
		transport.notifications[1..].clone()
	}
	return message
}

fn (mut transport PluginMCPHTTPTransport) close() {
	if transport.session_id.len == 0 {
		return
	}
	mut header := http.new_header()
	header.add_custom_map(plugin_mcp_http_user_headers(transport.headers)) or { return }
	header.set_custom('MCP-Session-Id', transport.session_id) or { return }
	if transport.protocol_version.len > 0 {
		header.set_custom('MCP-Protocol-Version', transport.protocol_version) or { return }
	}
	_ := http.fetch(
		url:                  transport.url
		method:               .delete
		header:               header
		validate:             transport.url.starts_with('https://')
		allow_redirect:       false
		max_retries:          1
		read_timeout:         plugin_mcp_http_close_timeout
		write_timeout:        plugin_mcp_http_close_timeout
		stop_copying_limit:   max_plugin_mcp_http_body_bytes + 1
		stop_receiving_limit: max_plugin_mcp_http_body_bytes + 1
	) or { return }
	transport.session_id = ''
}

fn plugin_mcp_http_user_headers(configured map[string]string) map[string]string {
	mut headers := map[string]string{}
	for name, value in configured {
		if name.to_lower() in ['accept', 'connection', 'content-length', 'content-type', 'host',
			'mcp-protocol-version', 'mcp-session-id', 'transfer-encoding', 'upgrade'] {
			continue
		}
		headers[name] = value
	}
	return headers
}

fn plugin_mcp_http_protocol_version(message string) string {
	envelope := json2.decode[map[string]json2.Any](message) or { return '' }
	result := envelope['result'] or { return '' }
	if result !is map[string]json2.Any {
		return ''
	}
	version := (result as map[string]json2.Any)['protocolVersion'] or { return '' }
	if version !is string {
		return ''
	}
	value := version as string
	if value.len > 128 || !valid_plugin_mcp_http_header_value(value) {
		return ''
	}
	return value
}

fn plugin_mcp_http_has_jsonrpc_error(message string) bool {
	envelope := json2.decode[map[string]json2.Any](message) or { return false }
	error_value := envelope['error'] or { return false }
	return error_value is map[string]json2.Any
}

fn plugin_mcp_http_request_headers(message string) (string, string, string) {
	envelope := json2.decode[map[string]json2.Any](message) or { return '', '', '' }
	method_value := envelope['method'] or { return '', '', '' }
	if method_value !is string {
		return '', '', ''
	}
	method := method_value as string
	params_value := envelope['params'] or { return '', method, '' }
	if params_value !is map[string]json2.Any {
		return '', method, ''
	}
	params := params_value as map[string]json2.Any
	meta_value := params['_meta'] or { return '', method, '' }
	if meta_value !is map[string]json2.Any {
		return '', method, ''
	}
	meta := meta_value as map[string]json2.Any
	version_value := meta['io.modelcontextprotocol/protocolVersion'] or {
		return '', method, ''
	}
	if version_value !is string {
		return '', method, ''
	}
	version := version_value as string
	name := if method in ['tools/call', 'prompts/get'] {
		plugin_mcp_json_string(params, 'name')
	} else if method == 'resources/read' {
		plugin_mcp_json_string(params, 'uri')
	} else {
		''
	}
	return version, method, name
}

fn plugin_mcp_json_string(fields map[string]json2.Any, key string) string {
	value := fields[key] or { return '' }
	if value !is string {
		return ''
	}
	return value as string
}

struct PluginMCPHTTPSseStream {
mut:
	carry      []u8
	event_name string
	data_lines []string
	bytes      int
}

fn (mut stream PluginMCPHTTPSseStream) feed(chunk []u8) ![]string {
	if chunk.len == 0 {
		return []string{}
	}
	for b in chunk {
		if b == 0 {
			return error('MCP HTTP SSE chunk contained a NUL byte')
		}
	}
	stream.bytes += chunk.len
	if stream.bytes > max_plugin_mcp_http_body_bytes {
		return error('MCP HTTP SSE response exceeds the message size limit')
	}
	mut text := []u8{cap: stream.carry.len + chunk.len}
	if stream.carry.len > 0 {
		text << stream.carry
		stream.carry = []u8{}
	}
	text << chunk
	mut messages := []string{}
	mut start := 0
	for start < text.len {
		mut end := start
		for end < text.len && text[end] != `\n` {
			end++
		}
		if end >= text.len {
			stream.carry = text[start..].clone()
			break
		}
		mut line := text[start..end].bytestr()
		start = end + 1
		if line.ends_with('\r') {
			line = line[..line.len - 1]
		}
		if line.len == 0 {
			append_plugin_mcp_http_sse_event(mut messages, stream.event_name, stream.data_lines)!
			stream.event_name = ''
			stream.data_lines.clear()
			continue
		}
		if line.starts_with(':') {
			continue
		}
		if line.starts_with('event:') {
			stream.event_name = line[6..].trim_space()
		} else if line.starts_with('data:') {
			data := line[5..]
			stream.data_lines << if data.starts_with(' ') { data[1..] } else { data }
		}
	}
	return messages
}

fn (mut stream PluginMCPHTTPSseStream) finish() ![]string {
	mut messages := []string{}
	if stream.carry.len > 0 {
		line_bytes := stream.carry
		stream.carry = []u8{}
		mut trim_end := line_bytes.len
		if trim_end > 0 && line_bytes[trim_end - 1] == `\r` {
			trim_end--
		}
		line := line_bytes[..trim_end].bytestr()
		if line.len > 0 && !line.starts_with(':') {
			if line.starts_with('event:') {
				stream.event_name = line[6..].trim_space()
			} else if line.starts_with('data:') {
				data := line[5..]
				stream.data_lines << if data.starts_with(' ') { data[1..] } else { data }
			}
		}
	}
	append_plugin_mcp_http_sse_event(mut messages, stream.event_name, stream.data_lines)!
	stream.event_name = ''
	stream.data_lines.clear()
	return messages
}

fn parse_plugin_mcp_http_sse(body string) ![]string {
	mut stream := PluginMCPHTTPSseStream{}
	mut messages := stream.feed(body.bytes())!
	messages << stream.finish()!
	if messages.len == 0 {
		return error('MCP HTTP SSE response contained no message events')
	}
	return messages
}

fn append_plugin_mcp_http_sse_event(mut messages []string, event_name string, data_lines []string) ! {
	if data_lines.len == 0 || (event_name.len > 0 && event_name != 'message') {
		return
	}
	message := data_lines.join('\n')
	if message.contains('\0') {
		return error('MCP HTTP SSE message contained a NUL byte')
	}
	if message.len == 0 || message.len > max_plugin_mcp_http_body_bytes {
		return error('MCP HTTP SSE message exceeds the size limit')
	}
	if messages.len >= max_plugin_mcp_http_messages {
		return error('MCP HTTP SSE response exceeded the message count limit')
	}
	messages << message
}

fn valid_plugin_mcp_http_header_value(value string) bool {
	for c in value {
		if c == `\r` || c == `\n` || c == 0 || (c < 32 && c != `\t`) || c == 127 {
			return false
		}
	}
	return true
}

fn new_plugin_mcp_http_client(server PluginMCPServer) !mcp.Client {
	connection := new_plugin_mcp_http_connection(server)!
	return connection.client
}

fn new_plugin_mcp_http_connection(server PluginMCPServer) !PluginMCPConnection {
	mut transport := new_plugin_mcp_http_transport(server)!
	return PluginMCPConnection{
		client:         mcp.new_client(transport, mcp.ClientConfig{
			protocol_version: mcp.latest_protocol_version
		})
		http_transport: transport
	}
}
