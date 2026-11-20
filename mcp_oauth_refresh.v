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
	// Secret handling (issue #741): in keychain mode the refresh token lives
	// in the OS keychain; the JSON file keeps only non-secret metadata.
	mode         string // keychain | file
	backend      SecretBackend
	scope        string
	secret_error string
	unavailable  map[string]bool
}

fn mcp_oauth_refresh_account(scope string, name string) string {
	return 'mcp-oauth-refresh/${scope}/${name}'
}

fn new_mcp_oauth_refresh_state(path string) &MCPOAuthRefreshState {
	return new_mcp_oauth_refresh_state_with(path, secret_mode_for_new_state(),
		native_secret_backend())
}

fn new_mcp_oauth_refresh_state_with(path string, requested_mode string, backend SecretBackend) &MCPOAuthRefreshState {
	mut mode := if path == '' || requested_mode == 'file' { 'file' } else { 'keychain' }
	mut chosen := backend
	if requested_mode == 'invalid' && path != '' {
		chosen = UnavailableSecretBackend{
			reason: 'VEASEL_SECRET_STORE must be `keychain` or `file`'
		}
		mode = 'keychain'
	}
	mut state := &MCPOAuthRefreshState{
		path:        path
		settings:    PersistedMCPOAuthRefresh{
			credentials: map[string]MCPOAuthRefreshRecord{}
		}
		mode:        mode
		backend:     chosen
		scope:       if path != '' { secret_account_scope(path) } else { '' }
		unavailable: map[string]bool{}
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
			// In keychain mode the on-disk refresh_token is empty: the
			// record is a metadata placeholder for a keychain entry.
			if record.token_endpoint.len == 0 || record.client_id.len == 0 {
				continue
			}
			// An empty refresh_token is a keychain placeholder: keep it so
			// sync can load (keychain mode) or restore (file mode) the token.
			credentials[name] = record
		}
		state.settings.credentials = credentials
	}
	state.sync_refresh_secrets()
	return state
}

// sync_refresh_secrets mirrors MCPCredentialState.sync_secrets (#741):
// verified keychain writes before any plaintext rewrite; fail closed.
fn (mut state MCPOAuthRefreshState) sync_refresh_secrets() {
	if state.path == '' {
		return
	}
	mut plaintext := []string{}
	mut placeholders := []string{}
	for name, record in state.settings.credentials {
		if record.refresh_token.len > 0 {
			plaintext << name
		} else {
			placeholders << name
		}
	}
	if state.mode == 'keychain' {
		plaintext.sort()
		for name in plaintext {
			encoded := json2.encode(state.settings.credentials[name])
			state.keychain_write_verified(mcp_oauth_refresh_account(state.scope, name),
				encoded) or {
				state.secret_error = err.msg()
				state.mark_refresh_unavailable(plaintext)
				return
			}
		}
		if plaintext.len > 0 {
			state.persist(state.settings) or {
				state.mark_refresh_unavailable(plaintext)
				return
			}
		}
		placeholders.sort()
		for name in placeholders {
			if name in state.unavailable {
				continue
			}
			stored := state.backend.get(mcp_oauth_refresh_account(state.scope, name)) or {
				state.unavailable[name] = true
				state.secret_error = with_keychain_hint(err.msg())
				continue
			}
			if stored.len == 0 {
				state.unavailable[name] = true
				state.secret_error = with_keychain_hint('the keychain entry for MCP OAuth credential ${name} is missing; authorize again')
				continue
			}
			decoded := json2.decode[MCPOAuthRefreshRecord](stored) or {
				state.unavailable[name] = true
				state.secret_error = with_keychain_hint('the keychain entry for MCP OAuth credential ${name} is unreadable')
				continue
			}
			state.settings.credentials[name] = decoded
		}
	} else if placeholders.len > 0 {
		mut restored := state.settings.credentials.clone()
		placeholders.sort()
		for name in placeholders {
			stored := state.backend.get(mcp_oauth_refresh_account(state.scope, name)) or {
				state.unavailable[name] = true
				state.secret_error = with_keychain_hint(err.msg())
				continue
			}
			if stored.len == 0 {
				state.unavailable[name] = true
				continue
			}
			decoded := json2.decode[MCPOAuthRefreshRecord](stored) or {
				state.unavailable[name] = true
				continue
			}
			restored[name] = decoded
		}
		mut failed := false
		for name in placeholders {
			if name in state.unavailable {
				failed = true
			}
		}
		if failed {
			// No keychain copy exists to restore (for example a legacy
			// file with an empty token): keep the old not-found semantics.
			for name in placeholders {
				if name in state.unavailable {
					state.settings.credentials.delete(name)
				}
			}
		}
		if !failed {
			updated := PersistedMCPOAuthRefresh{
				credentials: restored
			}
			state.persist(updated) or {
				state.secret_error = with_keychain_hint(err.msg())
				return
			}
			state.settings = updated
			for name in placeholders {
				state.backend.delete(mcp_oauth_refresh_account(state.scope, name)) or {}
			}
		}
	}
}

fn (mut state MCPOAuthRefreshState) mark_refresh_unavailable(names []string) {
	for name in names {
		state.unavailable[name] = true
		record := state.settings.credentials[name]
		state.settings.credentials[name] = MCPOAuthRefreshRecord{
			...record
			refresh_token: ''
		}
	}
	if state.secret_error == '' {
		state.secret_error = with_keychain_hint('MCP OAuth refresh migration to the OS keychain failed')
	}
}

fn (mut state MCPOAuthRefreshState) keychain_write_verified(account string, value string) ! {
	state.backend.set(account, value) or { return error(with_keychain_hint(err.msg())) }
	stored := state.backend.get(account) or { return error(with_keychain_hint(err.msg())) }
	if stored != value {
		return error(with_keychain_hint('keychain read-back did not match the value written'))
	}
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
	if state.mode == 'keychain' && state.path != '' {
		state.keychain_write_verified(mcp_oauth_refresh_account(state.scope, name),
			json2.encode(record)) or { return error(err.msg()) }
	}
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
	state.unavailable.delete(name)
}

fn (mut state MCPOAuthRefreshState) get(name string) !MCPOAuthRefreshRecord {
	state.mu.lock()
	defer {
		state.mu.unlock()
	}
	if name !in state.settings.credentials {
		return error('OAuth refresh metadata not found for credential')
	}
	if name in state.unavailable {
		return error(state.secret_error)
	}
	return state.settings.credentials[name]
}

fn (mut state MCPOAuthRefreshState) has(name string) bool {
	state.mu.lock()
	defer {
		state.mu.unlock()
	}
	return name in state.settings.credentials
}

fn (mut state MCPOAuthRefreshState) remove(name string) ! {
	state.mu.lock()
	defer {
		state.mu.unlock()
	}
	if name !in state.settings.credentials {
		return
	}
	if state.mode == 'keychain' && state.path != '' {
		state.backend.delete(mcp_oauth_refresh_account(state.scope, name)) or {
			return error(with_keychain_hint(err.msg()))
		}
	}
	mut credentials := state.settings.credentials.clone()
	credentials.delete(name)
	updated := PersistedMCPOAuthRefresh{
		credentials: credentials
	}
	state.persist(updated)!
	state.settings = updated
	state.unavailable.delete(name)
}

// persist writes the on-disk form: in keychain mode refresh tokens are
// blanked (they stay in the keychain); metadata remains for discovery.
fn (mut state MCPOAuthRefreshState) persist(settings PersistedMCPOAuthRefresh) ! {
	if state.path == '' {
		state.settings = settings
		return
	}
	mut on_disk := settings
	if state.mode == 'keychain' {
		mut redacted := map[string]MCPOAuthRefreshRecord{}
		for name, record in settings.credentials {
			redacted[name] = MCPOAuthRefreshRecord{
				...record
				refresh_token: ''
			}
		}
		on_disk = PersistedMCPOAuthRefresh{
			credentials: redacted
		}
	}
	encoded := json2.encode[PersistedMCPOAuthRefresh](on_disk)
	ensure_directory(os.dir(state.path))!
	write_private_file_atomic(state.path, encoded)!
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
