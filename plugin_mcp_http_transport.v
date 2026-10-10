module main

import mcp
import json2
import net.http
import time

const max_plugin_mcp_http_body_bytes = 1_000_000
const max_plugin_mcp_http_messages = 64
const plugin_mcp_http_response_timeout = 20 * time.second
const plugin_mcp_http_close_timeout = 250 * time.millisecond

// PluginMCPHTTPTransport adapts bounded Streamable HTTP requests to the
// MCP client transport interface. Redirects and automatic retries are disabled
// because configured plugin headers are bound to the configured origin and a
// retried tools/call request could repeat side effects.
struct PluginMCPHTTPTransport {
mut:
	url              string
	headers          map[string]string
	session_id       string
	protocol_version string
	pending          []string
}

fn new_plugin_mcp_http_transport(server PluginMCPServer) !PluginMCPHTTPTransport {
	if server.transport != 'streamable-http' || server.url.len == 0 {
		return error('unsupported Agent Plugin MCP HTTP server')
	}
	return PluginMCPHTTPTransport{
		url:     server.url
		headers: server.headers.clone()
	}
}

fn (mut transport PluginMCPHTTPTransport) send(message string) ! {
	if message.len == 0 || message.len > max_plugin_mcp_http_body_bytes {
		return error('MCP HTTP request exceeds the message size limit')
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
	)!
	if response.status_code in 300 .. 400 {
		return error('MCP HTTP redirects are disabled to protect configured headers')
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

fn parse_plugin_mcp_http_sse(body string) ![]string {
	mut messages := []string{}
	mut event_name := ''
	mut data_lines := []string{}
	for line in body.split_into_lines() {
		if line.len == 0 {
			append_plugin_mcp_http_sse_event(mut messages, event_name, data_lines)!
			event_name = ''
			data_lines.clear()
			continue
		}
		if line.starts_with(':') {
			continue
		}
		if line.starts_with('event:') {
			event_name = line[6..].trim_space()
		} else if line.starts_with('data:') {
			data := line[5..]
			data_lines << if data.starts_with(' ') { data[1..] } else { data }
		}
	}
	append_plugin_mcp_http_sse_event(mut messages, event_name, data_lines)!
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
	transport := new_plugin_mcp_http_transport(server)!
	return mcp.new_client(transport, mcp.ClientConfig{
		protocol_version: mcp.latest_protocol_version
	})
}
