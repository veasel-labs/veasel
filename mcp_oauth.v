module main

import net.urllib
import strings

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
