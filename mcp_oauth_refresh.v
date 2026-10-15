module main

import json2
import net.http
import net.urllib
import os
import sync

// Owner-only refresh metadata for MCP OAuth credentials. Access tokens stay in
// mcp-credentials.json Authorization headers; refresh secrets never appear in API views.
struct MCPOAuthRefreshRecord {
pub:
	refresh_token  string
	token_endpoint string
	client_id      string
	resource       string
	scope          string
}

struct PersistedMCPOAuthRefresh {
mut:
	credentials map[string]MCPOAuthRefreshRecord
}

@[heap]
struct MCPOAuthRefreshState {
mut:
	mu       sync.Mutex
	path     string
	settings PersistedMCPOAuthRefresh
}

fn new_mcp_oauth_refresh_state(path string) &MCPOAuthRefreshState {
	mut state := &MCPOAuthRefreshState{
		path:     path
		settings: PersistedMCPOAuthRefresh{
			credentials: map[string]MCPOAuthRefreshRecord{}
		}
	}
	if path != '' && os.is_file(path) {
		loaded := json2.decode[PersistedMCPOAuthRefresh](os.read_file(path) or { '' }) or {
			return state
		}
		mut credentials := map[string]MCPOAuthRefreshRecord{}
		for name, record in loaded.credentials {
			if !is_valid_mcp_credential_name(name) {
				continue
			}
			if record.refresh_token.len == 0 || record.token_endpoint.len == 0
				|| record.client_id.len == 0 {
				continue
			}
			credentials[name] = record
		}
		state.settings.credentials = credentials
	}
	return state
}

fn (store &Store) mcp_oauth_refresh_path() string {
	if store.path == ':memory:' {
		return ''
	}
	return os.join_path(os.dir(store.path), 'mcp-oauth-refresh.json')
}

fn (mut state MCPOAuthRefreshState) put(name string, record MCPOAuthRefreshRecord) ! {
	if !is_valid_mcp_credential_name(name) {
		return error('MCP credential name is invalid')
	}
	if record.refresh_token.len == 0 || record.refresh_token.len > max_mcp_oauth_access_token_len {
		return error('OAuth refresh_token is invalid')
	}
	_ := validate_mcp_oauth_resource_metadata_url(record.token_endpoint) or {
		return error('OAuth token_endpoint is invalid')
	}
	_ := validate_mcp_oauth_client_id(record.client_id)!
	state.mu.lock()
	defer {
		state.mu.unlock()
	}
	mut credentials := state.settings.credentials.clone()
	credentials[name] = record
	updated := PersistedMCPOAuthRefresh{
		credentials: credentials
	}
	state.persist(updated)!
	state.settings = updated
}

fn (mut state MCPOAuthRefreshState) get(name string) !MCPOAuthRefreshRecord {
	state.mu.lock()
	defer {
		state.mu.unlock()
	}
	if name !in state.settings.credentials {
		return error('OAuth refresh metadata not found for credential')
	}
	return state.settings.credentials[name]
}

fn (mut state MCPOAuthRefreshState) remove(name string) ! {
	state.mu.lock()
	defer {
		state.mu.unlock()
	}
	if name !in state.settings.credentials {
		return
	}
	mut credentials := state.settings.credentials.clone()
	credentials.delete(name)
	updated := PersistedMCPOAuthRefresh{
		credentials: credentials
	}
	state.persist(updated)!
	state.settings = updated
}

fn (mut state MCPOAuthRefreshState) persist(settings PersistedMCPOAuthRefresh) ! {
	if state.path == '' {
		state.settings = settings
		return
	}
	encoded := json2.encode[PersistedMCPOAuthRefresh](settings)
	os.write_file(state.path, encoded)!
	$if !windows {
		os.chmod(state.path, 0o600) or {}
	}
}

fn exchange_mcp_oauth_refresh_token(record MCPOAuthRefreshRecord) !MCPOAuthTokenSet {
	token_endpoint := validate_mcp_oauth_resource_metadata_url(record.token_endpoint) or {
		return error('OAuth token_endpoint is invalid')
	}
	client_id := validate_mcp_oauth_client_id(record.client_id)!
	if record.refresh_token.len == 0 || record.refresh_token.len > max_mcp_oauth_access_token_len {
		return error('OAuth refresh_token is invalid')
	}
	mut form := urllib.new_values()
	form.add('grant_type', 'refresh_token')
	form.add('refresh_token', record.refresh_token)
	form.add('client_id', client_id)
	if record.resource.len > 0 {
		form.add('resource', record.resource)
	}
	if record.scope.len > 0 {
		form.add('scope', record.scope)
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
	) or { return error('OAuth refresh request failed') }
	if response.status_code < 200 || response.status_code >= 300 {
		return error('OAuth token endpoint returned HTTP ${response.status_code}')
	}
	return parse_mcp_oauth_token_response(response.body)!
}

fn refresh_mcp_oauth_credential(mut refresh MCPOAuthRefreshState, mut credentials MCPCredentialState,
	name string) !MCPCredentialView {
	if !is_valid_mcp_credential_name(name) {
		return error('MCP credential name is invalid')
	}
	record := refresh.get(name)!
	tokens := exchange_mcp_oauth_refresh_token(record)!
	view := apply_mcp_oauth_tokens_to_credential(mut credentials, name, tokens)!
	next_refresh := if tokens.refresh_token.len > 0 {
		tokens.refresh_token
	} else {
		record.refresh_token
	}
	refresh.put(name, MCPOAuthRefreshRecord{
		refresh_token:  next_refresh
		token_endpoint: record.token_endpoint
		client_id:      record.client_id
		resource:       record.resource
		scope:          if tokens.scope.len > 0 { tokens.scope } else { record.scope }
	})!
	return view
}
