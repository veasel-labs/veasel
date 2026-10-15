module main

import crypto.rand
import crypto.sha256
import encoding.base64
import net.urllib
import time

const max_mcp_oauth_pkce_verifier_len = 128
const min_mcp_oauth_pkce_verifier_len = 43
const max_mcp_oauth_state_len = 128
const max_mcp_oauth_scope_len = 512
const max_mcp_oauth_client_id_len = 256

// MCPOAuthAuthorizeRequest holds the inputs needed to start an authorization
// code + PKCE (S256) flow against a discovered authorization server.
pub struct MCPOAuthAuthorizeRequest {
pub:
	authorization_endpoint string
	client_id              string
	redirect_uri           string
	scope                  string
	resource               string
}

// MCPOAuthAuthorizeSession is the secret-bearing state required to finish the
// code exchange. Persist only with owner-only file permissions; never log the
// verifier or include it in API responses.
pub struct MCPOAuthAuthorizeSession {
pub:
	state                  string
	code_verifier          string
	code_challenge         string
	code_challenge_method  string
	authorization_endpoint string
	token_endpoint         string
	client_id              string
	redirect_uri           string
	scope                  string
	resource               string
	authorize_url          string
	created_unix           i64
}

pub struct MCPOAuthCallbackResult {
pub:
	code              string
	state             string
	error             string
	error_description string
}

fn mcp_oauth_base64url_encode(data []u8) string {
	encoded := base64.encode(data)
	mut builder := []u8{cap: encoded.len}
	for c in encoded {
		match c {
			`+` {
				builder << `-`
			}
			`/` {
				builder << `_`
			}
			`=` {
				continue
			}
			else {
				builder << c
			}
		}
	}
	return builder.bytestr()
}

fn mcp_oauth_random_token(byte_len int) !string {
	if byte_len < 16 || byte_len > 64 {
		return error('OAuth random token size is invalid')
	}
	raw := rand.bytes(byte_len)!
	return mcp_oauth_base64url_encode(raw)
}

fn mcp_oauth_generate_pkce_pair() !(string, string) {
	verifier := mcp_oauth_random_token(32)!
	if verifier.len < min_mcp_oauth_pkce_verifier_len || verifier.len > max_mcp_oauth_pkce_verifier_len {
		return error('OAuth PKCE verifier length is invalid')
	}
	challenge := mcp_oauth_base64url_encode(sha256.sum256(verifier.bytes()))
	return verifier, challenge
}

fn validate_mcp_oauth_loopback_redirect_uri(value string) !string {
	trimmed := value.trim_space()
	if trimmed.len == 0 || trimmed.len > 2048 || trimmed.contains('\0') || trimmed.contains('\r')
		|| trimmed.contains('\n') || trimmed.contains('#') {
		return error('OAuth redirect_uri is invalid')
	}
	parsed := urllib.parse(trimmed) or { return error('OAuth redirect_uri is invalid') }
	scheme := parsed.scheme.to_lower()
	if scheme != 'http' {
		return error('OAuth redirect_uri must use http on loopback')
	}
	if userinfo := parsed.user {
		if userinfo.username != '' || userinfo.password != '' || userinfo.password_set {
			return error('OAuth redirect_uri must not contain user information')
		}
	}
	hostname := parsed.hostname().to_lower()
	if hostname !in ['127.0.0.1', 'localhost', '::1'] && !hostname.ends_with('.localhost') {
		return error('OAuth redirect_uri must target loopback')
	}
	path := parsed.path
	if path.len == 0 || !path.starts_with('/') || path.contains('\\') {
		return error('OAuth redirect_uri path is invalid')
	}
	return trimmed
}

fn validate_mcp_oauth_client_id(value string) !string {
	trimmed := value.trim_space()
	if trimmed.len == 0 || trimmed.len > max_mcp_oauth_client_id_len {
		return error('OAuth client_id is invalid')
	}
	for c in trimmed {
		if c < 32 || c == 127 {
			return error('OAuth client_id is invalid')
		}
	}
	return trimmed
}

fn validate_mcp_oauth_scope(value string) !string {
	trimmed := value.trim_space()
	if trimmed.len == 0 {
		return ''
	}
	if trimmed.len > max_mcp_oauth_scope_len {
		return error('OAuth scope is too long')
	}
	for c in trimmed {
		if c < 32 || c == 127 {
			return error('OAuth scope is invalid')
		}
	}
	return trimmed
}

fn build_mcp_oauth_authorize_session(request MCPOAuthAuthorizeRequest, token_endpoint string) !MCPOAuthAuthorizeSession {
	authorization_endpoint := validate_mcp_oauth_resource_metadata_url(request.authorization_endpoint) or {
		return error('OAuth authorization_endpoint is invalid')
	}
	token := validate_mcp_oauth_resource_metadata_url(token_endpoint) or {
		return error('OAuth token_endpoint is invalid')
	}
	client_id := validate_mcp_oauth_client_id(request.client_id)!
	redirect_uri := validate_mcp_oauth_loopback_redirect_uri(request.redirect_uri)!
	scope := validate_mcp_oauth_scope(request.scope)!
	mut resource := ''
	if request.resource.trim_space().len > 0 {
		resource = validate_mcp_oauth_resource_metadata_url(request.resource) or {
			return error('OAuth resource is invalid')
		}
	}
	state := mcp_oauth_random_token(24)!
	if state.len > max_mcp_oauth_state_len {
		return error('OAuth state is invalid')
	}
	verifier, challenge := mcp_oauth_generate_pkce_pair()!
	mut query := urllib.new_values()
	query.add('response_type', 'code')
	query.add('client_id', client_id)
	query.add('redirect_uri', redirect_uri)
	query.add('state', state)
	query.add('code_challenge', challenge)
	query.add('code_challenge_method', 'S256')
	if scope.len > 0 {
		query.add('scope', scope)
	}
	if resource.len > 0 {
		query.add('resource', resource)
	}
	separator := if authorization_endpoint.contains('?') { '&' } else { '?' }
	authorize_url := authorization_endpoint + separator + query.encode()
	return MCPOAuthAuthorizeSession{
		state:                  state
		code_verifier:          verifier
		code_challenge:         challenge
		code_challenge_method:  'S256'
		authorization_endpoint: authorization_endpoint
		token_endpoint:         token
		client_id:              client_id
		redirect_uri:           redirect_uri
		scope:                  scope
		resource:               resource
		authorize_url:          authorize_url
		created_unix:           time.now().unix()
	}
}

fn parse_mcp_oauth_callback_query(raw_query string) !MCPOAuthCallbackResult {
	trimmed := raw_query.trim_space()
	if trimmed.len == 0 || trimmed.len > 4096 {
		return error('OAuth callback query is invalid')
	}
	mut query_text := trimmed
	if query_text.contains('://') {
		parsed := urllib.parse(query_text) or { return error('OAuth callback URL is invalid') }
		validate_mcp_oauth_loopback_redirect_uri('${parsed.scheme}://${parsed.host}${parsed.path}')!
		query_text = parsed.raw_query
	} else if query_text.starts_with('?') {
		query_text = query_text[1..]
	}
	values := urllib.parse_query(query_text) or { return error('OAuth callback query is invalid') }
	code := (values.get('code') or { '' }).trim_space()
	state := (values.get('state') or { '' }).trim_space()
	err_code := (values.get('error') or { '' }).trim_space()
	err_desc := (values.get('error_description') or { '' }).trim_space()
	if state.len == 0 || state.len > max_mcp_oauth_state_len {
		return error('OAuth callback state is invalid')
	}
	if err_code.len > 0 {
		return MCPOAuthCallbackResult{
			state:             state
			error:             sanitize_mcp_auth_param(err_code, 128)
			error_description: sanitize_mcp_auth_param(err_desc, 512)
		}
	}
	if code.len == 0 || code.len > 2048 {
		return error('OAuth callback code is invalid')
	}
	for c in code {
		if c < 32 || c == 127 {
			return error('OAuth callback code is invalid')
		}
	}
	return MCPOAuthCallbackResult{
		code:  code
		state: state
	}
}

fn mcp_oauth_callback_matches_session(session MCPOAuthAuthorizeSession, callback MCPOAuthCallbackResult) !string {
	if callback.state != session.state {
		return error('OAuth callback state mismatch')
	}
	if callback.error.len > 0 {
		if callback.error_description.len > 0 {
			return error('OAuth authorization failed: ${callback.error} (${callback.error_description})')
		}
		return error('OAuth authorization failed: ${callback.error}')
	}
	if callback.code.len == 0 {
		return error('OAuth callback code is missing')
	}
	return callback.code
}
