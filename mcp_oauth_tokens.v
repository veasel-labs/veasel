module main

import json2
import net.http
import net.urllib
import os
import sync
import time

const max_mcp_oauth_pending_sessions = 32
const max_mcp_oauth_access_token_len = 8192
const mcp_oauth_token_timeout = 10 * time.second

pub struct MCPOAuthTokenSet {
pub:
	access_token  string
	token_type    string
	expires_in    int
	refresh_token string
	scope         string
}

struct PersistedMCPOAuthPending {
mut:
	sessions map[string]MCPOAuthAuthorizeSession
}

@[heap]
pub struct MCPOAuthPendingState {
mut:
	mu       sync.Mutex
	path     string
	sessions map[string]MCPOAuthAuthorizeSession
}

fn new_mcp_oauth_pending_state(path string) &MCPOAuthPendingState {
	mut state := &MCPOAuthPendingState{
		path:     path
		sessions: map[string]MCPOAuthAuthorizeSession{}
	}
	if path != '' && os.is_file(path) {
		loaded := json2.decode[PersistedMCPOAuthPending](os.read_file(path) or { '' }) or {
			return state
		}
		mut sessions := map[string]MCPOAuthAuthorizeSession{}
		for key, session in loaded.sessions {
			if key.len == 0 || key != session.state || session.code_verifier.len == 0 {
				continue
			}
			sessions[key] = session
		}
		state.sessions = sessions
	}
	return state
}

fn (store &Store) mcp_oauth_pending_path() string {
	if store.path == ':memory:' {
		return ''
	}
	return os.join_path(os.dir(store.path), 'mcp-oauth-pending.json')
}

fn (mut state MCPOAuthPendingState) put(session MCPOAuthAuthorizeSession) ! {
	state.mu.lock()
	defer {
		state.mu.unlock()
	}
	if session.state.len == 0 || session.code_verifier.len == 0 {
		return error('OAuth pending session is invalid')
	}
	if state.sessions.len >= max_mcp_oauth_pending_sessions && session.state !in state.sessions {
		return error('OAuth pending session limit (${max_mcp_oauth_pending_sessions}) reached')
	}
	mut sessions := state.sessions.clone()
	sessions[session.state] = session
	state.persist(sessions)!
	state.sessions = sessions
}

fn (mut state MCPOAuthPendingState) take(state_value string) !MCPOAuthAuthorizeSession {
	state.mu.lock()
	defer {
		state.mu.unlock()
	}
	if state_value.len == 0 || state_value !in state.sessions {
		return error('OAuth pending session not found')
	}
	session := state.sessions[state_value]
	mut sessions := state.sessions.clone()
	sessions.delete(state_value)
	state.persist(sessions)!
	state.sessions = sessions
	return session
}

fn (state &MCPOAuthPendingState) persist(sessions map[string]MCPOAuthAuthorizeSession) ! {
	if state.path == '' {
		return
	}
	os.mkdir_all(os.dir(state.path))!
	temporary_path := '${state.path}.tmp'
	payload := PersistedMCPOAuthPending{
		sessions: sessions
	}
	write_private_file(temporary_path, json2.encode(payload))!
	$if !windows {
		os.chmod(temporary_path, 0o600)!
	}
	os.mv(temporary_path, state.path)!
}

fn parse_mcp_oauth_token_response(body string) !MCPOAuthTokenSet {
	if body.len == 0 || body.len > max_mcp_oauth_metadata_bytes {
		return error('OAuth token response is invalid')
	}
	fields := json2.decode[map[string]json2.Any](body) or {
		return error('OAuth token response JSON is invalid')
	}
	access := mcp_oauth_required_token_string(fields, 'access_token', max_mcp_oauth_access_token_len)!
	mut token_type := 'bearer'
	if value := fields['token_type'] {
		if value is string {
			cleaned := sanitize_mcp_auth_param(value as string, 64).to_lower()
			if cleaned.len > 0 {
				token_type = cleaned
			}
		}
	}
	mut expires_in := 0
	if value := fields['expires_in'] {
		match value {
			i64 {
				expires_in = int(value)
			}
			f64 {
				expires_in = int(value)
			}
			string {
				expires_in = value.int()
			}
			else {}
		}
	}
	if expires_in < 0 {
		expires_in = 0
	}
	mut refresh := ''
	if value := fields['refresh_token'] {
		if value is string {
			refresh = sanitize_mcp_auth_param(value as string, max_mcp_oauth_access_token_len)
		}
	}
	mut scope := ''
	if value := fields['scope'] {
		if value is string {
			scope = validate_mcp_oauth_scope(value as string) or { '' }
		}
	}
	return MCPOAuthTokenSet{
		access_token:  access
		token_type:    token_type
		expires_in:    expires_in
		refresh_token: refresh
		scope:         scope
	}
}

fn mcp_oauth_required_token_string(fields map[string]json2.Any, key string, max_len int) !string {
	value := fields[key] or { return error('OAuth token response missing ${key}') }
	if value !is string {
		return error('OAuth token response field `${key}` must be a string')
	}
	trimmed := (value as string).trim_space()
	if trimmed.len == 0 || trimmed.len > max_len {
		return error('OAuth token response field `${key}` is invalid')
	}
	for c in trimmed {
		if c < 32 || c == 127 {
			return error('OAuth token response field `${key}` is invalid')
		}
	}
	return trimmed
}

fn exchange_mcp_oauth_authorization_code(session MCPOAuthAuthorizeSession, code string) !MCPOAuthTokenSet {
	if code.len == 0 || code.len > 2048 {
		return error('OAuth authorization code is invalid')
	}
	token_endpoint := validate_mcp_oauth_resource_metadata_url(session.token_endpoint) or {
		return error('OAuth token_endpoint is invalid')
	}
	mut form := urllib.new_values()
	form.add('grant_type', 'authorization_code')
	form.add('code', code)
	form.add('redirect_uri', session.redirect_uri)
	form.add('client_id', session.client_id)
	form.add('code_verifier', session.code_verifier)
	if session.resource.len > 0 {
		form.add('resource', session.resource)
	}
	mut header := http.new_header()
	header.set(.content_type, 'application/x-www-form-urlencoded')
	header.set(.accept, 'application/json')
	response := http.fetch(
		url:                  token_endpoint
		method:               .post
		header:               header
		data:                 form.encode()
		validate:             token_endpoint.starts_with('https://')
		allow_redirect:       false
		max_retries:          1
		read_timeout:         mcp_oauth_token_timeout
		write_timeout:        mcp_oauth_token_timeout
		stop_copying_limit:   max_mcp_oauth_metadata_bytes + 1
		stop_receiving_limit: max_mcp_oauth_metadata_bytes + 1
	) or { return error('OAuth token request failed') }
	if response.status_code < 200 || response.status_code >= 300 {
		return error('OAuth token endpoint returned HTTP ${response.status_code}')
	}
	return parse_mcp_oauth_token_response(response.body)!
}

fn mcp_oauth_authorization_header_value(tokens MCPOAuthTokenSet) !string {
	token_type := if tokens.token_type.len > 0 { tokens.token_type } else { 'bearer' }
	if token_type != 'bearer' {
		return error('OAuth token_type `${token_type}` is unsupported')
	}
	if tokens.access_token.len == 0 {
		return error('OAuth access_token is missing')
	}
	value := 'Bearer ${tokens.access_token}'
	if !valid_http_header('Authorization', value) {
		return error('OAuth access_token produces an invalid Authorization header')
	}
	return value
}

fn apply_mcp_oauth_tokens_to_credential(mut credentials MCPCredentialState, name string, tokens MCPOAuthTokenSet) !MCPCredentialView {
	header_value := mcp_oauth_authorization_header_value(tokens)!
	return credentials.upsert(MCPCredentialInput{
		name:    name
		headers: {
			'Authorization': header_value
		}
	})
}

fn complete_mcp_oauth_authorization_code(mut pending MCPOAuthPendingState, mut credentials MCPCredentialState,
	mut refresh MCPOAuthRefreshState, credential_name string, callback MCPOAuthCallbackResult) !MCPCredentialView {
	if !is_valid_mcp_credential_name(credential_name) {
		return error('MCP credential name is invalid')
	}
	session := pending.take(callback.state)!
	code := mcp_oauth_callback_matches_session(session, callback)!
	tokens := exchange_mcp_oauth_authorization_code(session, code)!
	view := apply_mcp_oauth_tokens_to_credential(mut credentials, credential_name, tokens)!
	if tokens.refresh_token.len > 0 {
		refresh.put(credential_name, MCPOAuthRefreshRecord{
			refresh_token:  tokens.refresh_token
			token_endpoint: session.token_endpoint
			client_id:      session.client_id
			resource:       session.resource
			scope:          if tokens.scope.len > 0 { tokens.scope } else { session.scope }
		})!
	}
	return view
}
