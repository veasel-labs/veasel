module main

import json2
import net.http
import net.urllib
import strings
import time

const max_mcp_oauth_metadata_bytes = 65_536
const max_mcp_oauth_metadata_servers = 8
const max_mcp_oauth_metadata_scopes = 32
const mcp_oauth_metadata_timeout = 5 * time.second

// MCPAuthChallenge holds safe fields from a WWW-Authenticate Bearer challenge
// (RFC 6750) plus optional resource_metadata (RFC 9728). Values are discovery
// hints only; Veasel does not perform the interactive OAuth authorization code
// dance or store tokens from these challenges.
pub struct MCPAuthChallenge {
pub:
	scheme            string
	realm             string
	scope             string
	error             string
	error_description string
	resource_metadata string
}

// MCPProtectedResourceMetadata is the subset of RFC 9728 protected-resource
// metadata Veasel surfaces for credential binding. Fetches never forward MCP
// server headers or secrets to the metadata URL.
pub struct MCPProtectedResourceMetadata {
pub:
	resource                 string
	authorization_servers    []string
	scopes_supported         []string
	bearer_methods_supported []string
}

fn mcp_auth_challenge_from_params(scheme string, params map[string]string) MCPAuthChallenge {
	mut realm := ''
	mut scope := ''
	mut err_code := ''
	mut err_desc := ''
	mut metadata := ''
	if value := params['realm'] {
		realm = sanitize_mcp_auth_param(value, 256)
	}
	if value := params['scope'] {
		scope = sanitize_mcp_auth_param(value, 512)
	}
	if value := params['error'] {
		err_code = sanitize_mcp_auth_param(value, 128)
	}
	if value := params['error_description'] {
		err_desc = sanitize_mcp_auth_param(value, 512)
	}
	if value := params['resource_metadata'] {
		if validated := validate_mcp_oauth_resource_metadata_url(value) {
			metadata = validated
		}
	}
	return MCPAuthChallenge{
		scheme:            scheme
		realm:             realm
		scope:             scope
		error:             err_code
		error_description: err_desc
		resource_metadata: metadata
	}
}

fn parse_www_authenticate_challenges(header string) []MCPAuthChallenge {
	trimmed := header.trim_space()
	if trimmed.len == 0 || trimmed.len > 4096 {
		return []MCPAuthChallenge{}
	}
	mut challenges := []MCPAuthChallenge{}
	for raw in split_www_authenticate_challenges(trimmed) {
		challenge := parse_www_authenticate_challenge(raw) or { continue }
		challenges << challenge
	}
	return challenges
}

fn parse_www_authenticate_bearer(header string) ?MCPAuthChallenge {
	for challenge in parse_www_authenticate_challenges(header) {
		if challenge.scheme == 'bearer' {
			return challenge
		}
	}
	return none
}

fn mcp_auth_challenge_summary(challenge MCPAuthChallenge) string {
	mut parts := []string{cap: 6}
	parts << challenge.scheme
	if challenge.realm.len > 0 {
		parts << 'realm=${challenge.realm}'
	}
	if challenge.scope.len > 0 {
		parts << 'scope=${challenge.scope}'
	}
	if challenge.error.len > 0 {
		parts << 'error=${challenge.error}'
	}
	if challenge.error_description.len > 0 {
		parts << 'error_description=${challenge.error_description}'
	}
	if challenge.resource_metadata.len > 0 {
		parts << 'resource_metadata=${challenge.resource_metadata}'
	}
	return parts.join(' ')
}

fn mcp_protected_resource_metadata_summary(metadata MCPProtectedResourceMetadata) string {
	mut parts := []string{cap: 4}
	if metadata.resource.len > 0 {
		parts << 'resource=${metadata.resource}'
	}
	if metadata.authorization_servers.len > 0 {
		parts << 'authorization_servers=${metadata.authorization_servers.join(',')}'
	}
	if metadata.scopes_supported.len > 0 {
		parts << 'scopes_supported=${metadata.scopes_supported.join(',')}'
	}
	if metadata.bearer_methods_supported.len > 0 {
		parts << 'bearer_methods=${metadata.bearer_methods_supported.join(',')}'
	}
	return parts.join(' ')
}

fn parse_mcp_protected_resource_metadata(body string) !MCPProtectedResourceMetadata {
	if body.len == 0 || body.len > max_mcp_oauth_metadata_bytes {
		return error('MCP OAuth resource metadata response is invalid')
	}
	fields := json2.decode[map[string]json2.Any](body) or {
		return error('MCP OAuth resource metadata JSON is invalid')
	}
	mut resource := ''
	if value := fields['resource'] {
		if value is string {
			resource = sanitize_mcp_auth_param(value as string, 2048)
		}
	}
	authorization_servers := parse_mcp_oauth_url_list(fields, 'authorization_servers',
		max_mcp_oauth_metadata_servers)!
	scopes_supported := parse_mcp_oauth_string_list(fields, 'scopes_supported', max_mcp_oauth_metadata_scopes)
	bearer_methods := parse_mcp_oauth_string_list(fields, 'bearer_methods_supported', 8)
	if resource.len == 0 && authorization_servers.len == 0 && scopes_supported.len == 0 {
		return error('MCP OAuth resource metadata is empty')
	}
	return MCPProtectedResourceMetadata{
		resource:                 resource
		authorization_servers:    authorization_servers
		scopes_supported:         scopes_supported
		bearer_methods_supported: bearer_methods
	}
}

fn parse_mcp_oauth_string_list(fields map[string]json2.Any, key string, max_items int) []string {
	value := fields[key] or { return []string{} }
	if value !is []json2.Any {
		return []string{}
	}
	mut items := []string{cap: max_items}
	for entry in value as []json2.Any {
		if items.len >= max_items {
			break
		}
		if entry is string {
			cleaned := sanitize_mcp_auth_param(entry as string, 256)
			if cleaned.len > 0 {
				items << cleaned
			}
		}
	}
	return items
}

fn parse_mcp_oauth_url_list(fields map[string]json2.Any, key string, max_items int) ![]string {
	value := fields[key] or { return []string{} }
	if value !is []json2.Any {
		return error('MCP OAuth metadata field `${key}` must be an array')
	}
	mut items := []string{cap: max_items}
	for entry in value as []json2.Any {
		if items.len >= max_items {
			break
		}
		if entry is string {
			if validated := validate_mcp_oauth_resource_metadata_url(entry as string) {
				items << validated
			}
		}
	}
	return items
}

fn fetch_mcp_protected_resource_metadata(url string) !MCPProtectedResourceMetadata {
	validated := validate_mcp_oauth_resource_metadata_url(url) or {
		return error('MCP OAuth resource metadata URL is invalid')
	}
	mut header := http.new_header()
	header.set(.accept, 'application/json')
	response := http.fetch(
		url:                  validated
		method:               .get
		header:               header
		validate:             validated.starts_with('https://')
		allow_redirect:       false
		max_retries:          1
		read_timeout:         mcp_oauth_metadata_timeout
		write_timeout:        mcp_oauth_metadata_timeout
		stop_copying_limit:   max_mcp_oauth_metadata_bytes + 1
		stop_receiving_limit: max_mcp_oauth_metadata_bytes + 1
	) or { return error('MCP OAuth resource metadata request failed') }
	if response.status_code < 200 || response.status_code >= 300 {
		return error('MCP OAuth resource metadata returned HTTP ${response.status_code}')
	}
	if response.body.len > max_mcp_oauth_metadata_bytes {
		return error('MCP OAuth resource metadata response is too large')
	}
	return parse_mcp_protected_resource_metadata(response.body)!
}

fn split_www_authenticate_challenges(header string) []string {
	mut challenges := []string{}
	mut start := 0
	mut in_quotes := false
	mut i := 0
	for i < header.len {
		c := header[i]
		if c == `"` {
			in_quotes = !in_quotes
			i++
			continue
		}
		if !in_quotes && c == `,` {
			rest := header[i + 1..].trim_space()
			if looks_like_www_authenticate_scheme_start(rest) {
				piece := header[start..i].trim_space()
				if piece.len > 0 {
					challenges << piece
				}
				start = i + 1
			}
		}
		i++
	}
	tail := header[start..].trim_space()
	if tail.len > 0 {
		challenges << tail
	}
	return challenges
}

fn looks_like_www_authenticate_scheme_start(value string) bool {
	if value.len == 0 {
		return false
	}
	mut i := 0
	for i < value.len {
		c := value[i]
		if (c >= `A` && c <= `Z`) || (c >= `a` && c <= `z`) || (c >= `0` && c <= `9`)
			|| c == `-` || c == `_` {
			i++
			continue
		}
		break
	}
	if i == 0 {
		return false
	}
	if i >= value.len {
		return true
	}
	return value[i] == ` ` || value[i] == `\t`
}

fn parse_www_authenticate_challenge(raw string) !MCPAuthChallenge {
	trimmed := raw.trim_space()
	if trimmed.len == 0 {
		return error('empty challenge')
	}
	mut scheme_end := 0
	for scheme_end < trimmed.len {
		c := trimmed[scheme_end]
		if (c >= `A` && c <= `Z`) || (c >= `a` && c <= `z`) || (c >= `0` && c <= `9`)
			|| c == `-` || c == `_` {
			scheme_end++
			continue
		}
		break
	}
	if scheme_end == 0 {
		return error('missing auth scheme')
	}
	scheme := trimmed[..scheme_end].to_lower()
	params_raw := trimmed[scheme_end..].trim_space()
	params := parse_www_authenticate_params(params_raw)!
	return mcp_auth_challenge_from_params(scheme, params)
}

fn parse_www_authenticate_params(raw string) !map[string]string {
	mut params := map[string]string{}
	mut i := 0
	for i < raw.len {
		for i < raw.len && (raw[i] == ` ` || raw[i] == `\t` || raw[i] == `,`) {
			i++
		}
		if i >= raw.len {
			break
		}
		mut key_start := i
		for i < raw.len {
			c := raw[i]
			if (c >= `A` && c <= `Z`) || (c >= `a` && c <= `z`) || (c >= `0` && c <= `9`)
				|| c == `-` || c == `_` {
				i++
				continue
			}
			break
		}
		if i == key_start || i >= raw.len || raw[i] != `=` {
			return error('invalid auth parameter')
		}
		key := raw[key_start..i].to_lower()
		i++
		if i >= raw.len {
			return error('missing auth parameter value')
		}
		mut value := ''
		if raw[i] == `"` {
			i++
			mut builder := strings.new_builder(32)
			for i < raw.len {
				c := raw[i]
				if c == `\\` && i + 1 < raw.len {
					builder.write_u8(raw[i + 1])
					i += 2
					continue
				}
				if c == `"` {
					i++
					break
				}
				builder.write_u8(c)
				i++
			}
			value = builder.str()
		} else {
			mut value_start := i
			for i < raw.len && raw[i] != `,` && raw[i] != ` ` && raw[i] != `\t` {
				i++
			}
			value = raw[value_start..i]
		}
		if key.len > 0 && key !in params {
			params[key] = value
		}
	}
	return params
}

fn sanitize_mcp_auth_param(value string, max_len int) string {
	trimmed := value.trim_space()
	if trimmed.len == 0 {
		return ''
	}
	mut builder := strings.new_builder(trimmed.len)
	for c in trimmed {
		if c < 32 || c == 127 {
			continue
		}
		builder.write_u8(c)
		if builder.len >= max_len {
			break
		}
	}
	return builder.str()
}

fn validate_mcp_oauth_resource_metadata_url(value string) ?string {
	trimmed := value.trim_space()
	if trimmed.len == 0 || trimmed.len > 2048 || trimmed.contains('\0') || trimmed.contains('\r')
		|| trimmed.contains('\n') || trimmed.contains('#') {
		return none
	}
	parsed := urllib.parse(trimmed) or { return none }
	scheme := parsed.scheme.to_lower()
	if scheme !in ['http', 'https'] || parsed.host == '' {
		return none
	}
	if userinfo := parsed.user {
		if userinfo.username != '' || userinfo.password != '' || userinfo.password_set {
			return none
		}
	}
	hostname := parsed.hostname().to_lower()
	if scheme != 'https' && hostname !in ['localhost', '127.0.0.1', '::1']
		&& !hostname.ends_with('.localhost') {
		return none
	}
	return trimmed
}
