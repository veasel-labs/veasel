module main

import json2
import os
import sync

const max_mcp_credentials = 32
const max_mcp_credential_name_len = 64

struct PersistedMCPCredentials {
mut:
	credentials map[string]map[string]string
}

pub struct MCPCredentialView {
pub:
	name          string
	header_names  []string @[json: 'header_names']
	oauth_refresh bool     @[json: 'oauth_refresh'; omitempty]
}

pub struct MCPCredentialCatalog {
pub:
	path        string @[omitempty]
	credentials []MCPCredentialView
}

pub struct MCPCredentialRemoval {
pub:
	removed string
}

struct MCPCredentialInput {
pub:
	name    string
	headers map[string]string
}

@[heap]
pub struct MCPCredentialState {
mut:
	mu       sync.Mutex
	path     string
	settings PersistedMCPCredentials
	// Secret handling (secret_store.v, issue #741): in keychain mode header
	// values live in the OS keychain; the JSON file keeps only header names.
	mode         string // keychain | file
	backend      SecretBackend
	scope        string
	secret_error string
	unavailable  map[string]bool // credentials whose saved headers cannot load now
}

fn mcp_credential_account(scope string, name string) string {
	return 'mcp-credential/${scope}/${name}'
}

// secret_mode_for_new_state mirrors model settings: keychain by default,
// VEASEL_SECRET_STORE=file opts into the owner-only plaintext file.
fn secret_mode_for_new_state() string {
	mut mode := parse_secret_store_mode(os.getenv('VEASEL_SECRET_STORE'))
	$if test {
		if os.getenv('VEASEL_SECRET_STORE') == '' {
			mode = 'file'
		}
	}
	return mode
}

fn new_mcp_credential_state(path string) &MCPCredentialState {
	return new_mcp_credential_state_with(path, secret_mode_for_new_state(),
		native_secret_backend())
}

fn new_mcp_credential_state_with(path string, requested_mode string, backend SecretBackend) &MCPCredentialState {
	mut mode := if path == '' || requested_mode == 'file' { 'file' } else { 'keychain' }
	mut chosen := backend
	if requested_mode == 'invalid' && path != '' {
		chosen = UnavailableSecretBackend{
			reason: 'VEASEL_SECRET_STORE must be `keychain` or `file`'
		}
		mode = 'keychain'
	}
	mut state := &MCPCredentialState{
		path:        path
		settings:    PersistedMCPCredentials{
			credentials: map[string]map[string]string{}
		}
		mode:        mode
		backend:     chosen
		scope:       if path != '' { secret_account_scope(path) } else { '' }
		unavailable: map[string]bool{}
	}
	if path != '' && os.is_file(path) {
		loaded := json2.decode[PersistedMCPCredentials](os.read_file(path) or { '' }) or {
			return state
		}
		mut credentials := map[string]map[string]string{}
		for name, headers in loaded.credentials {
			if !is_valid_mcp_credential_name(name) {
				continue
			}
			mut cleaned := map[string]string{}
			for key, value in headers {
				// An empty value is a keychain-mode placeholder: only the
				// header name is persisted on disk.
				if value == '' || valid_http_header(key, value) {
					cleaned[key] = value
				}
			}
			if cleaned.len > 0 {
				credentials[name] = cleaned
			}
		}
		state.settings.credentials = credentials
	}
	state.sync_secrets()
	return state
}

// sync_secrets reconciles disk and keychain at construction (callers may
// also be tests). Migration order mirrors provider keys (#690): every
// keychain write is read back identically BEFORE the plaintext file is
// rewritten without values; any failure leaves the file untouched and the
// affected credentials unusable (fail closed, never silent plaintext).
fn (mut state MCPCredentialState) sync_secrets() {
	if state.path == '' {
		return
	}
	mut plaintext := []string{}
	mut placeholders := []string{}
	for name, headers in state.settings.credentials {
		mut has_value := false
		for _, value in headers {
			if value.len > 0 {
				has_value = true
			}
		}
		if has_value {
			plaintext << name
		} else {
			placeholders << name
		}
	}
	if state.mode == 'keychain' {
		plaintext.sort()
		for name in plaintext {
			encoded := json2.encode(state.settings.credentials[name])
			state.keychain_write_verified(mcp_credential_account(state.scope, name),
				encoded) or {
				state.secret_error = err.msg()
				state.mark_unavailable(plaintext)
				return
			}
		}
		if plaintext.len > 0 {
			redacted := PersistedMCPCredentials{
				credentials: state.settings.credentials.clone()
			}
			state.persist(redacted) or {
				state.mark_unavailable(plaintext)
				return
			}
		}
		placeholders.sort()
		for name in placeholders {
			if name in state.unavailable {
				continue
			}
			stored := state.backend.get(mcp_credential_account(state.scope, name)) or {
				state.unavailable[name] = true
				state.secret_error = with_keychain_hint(err.msg())
				continue
			}
			if stored.len == 0 {
				state.unavailable[name] = true
				state.secret_error = with_keychain_hint('the keychain entry for MCP credential ${name} is missing; save the credential again')
				continue
			}
			decoded := json2.decode[map[string]string](stored) or {
				state.unavailable[name] = true
				state.secret_error = with_keychain_hint('the keychain entry for MCP credential ${name} is unreadable')
				continue
			}
			state.settings.credentials[name] = decoded
		}
	} else if placeholders.len > 0 {
		// Rollback (VEASEL_SECRET_STORE=file): copy keychain values back
		// into the owner-only file, then drop the keychain entries. Nothing
		// changes on disk unless every value could be read.
		mut restored := state.settings.credentials.clone()
		placeholders.sort()
		for name in placeholders {
			stored := state.backend.get(mcp_credential_account(state.scope, name)) or {
				state.unavailable[name] = true
				state.secret_error = with_keychain_hint(err.msg())
				continue
			}
			if stored.len == 0 {
				state.unavailable[name] = true
				continue
			}
			decoded := json2.decode[map[string]string](stored) or {
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
		if !failed {
			updated := PersistedMCPCredentials{
				credentials: restored
			}
			state.persist(updated) or {
				state.secret_error = with_keychain_hint(err.msg())
				return
			}
			state.settings = updated
			for name in placeholders {
				state.backend.delete(mcp_credential_account(state.scope, name)) or {}
			}
		}
	}
}

fn (mut state MCPCredentialState) mark_unavailable(names []string) {
	for name in names {
		state.unavailable[name] = true
		// Fail closed: plaintext must not be used while migration failed.
		mut emptied := map[string]string{}
		for key, _ in state.settings.credentials[name] {
			emptied[key] = ''
		}
		state.settings.credentials[name] = emptied
	}
	if state.secret_error == '' {
		state.secret_error = with_keychain_hint('MCP credential migration to the OS keychain failed')
	}
}

fn (mut state MCPCredentialState) keychain_write_verified(account string, value string) ! {
	state.backend.set(account, value) or { return error(with_keychain_hint(err.msg())) }
	stored := state.backend.get(account) or { return error(with_keychain_hint(err.msg())) }
	if stored != value {
		return error(with_keychain_hint('keychain read-back did not match the value written'))
	}
}

fn (store &Store) mcp_credentials_path() string {
	if store.path == ':memory:' {
		return ''
	}
	return os.join_path(os.dir(store.path), 'mcp-credentials.json')
}

fn is_valid_mcp_credential_name(name string) bool {
	return is_valid_configured_mcp_name(name)
}

fn (mut state MCPCredentialState) view() MCPCredentialCatalog {
	state.mu.lock()
	defer {
		state.mu.unlock()
	}
	mut credentials := []MCPCredentialView{cap: state.settings.credentials.len}
	for name in state.settings.credentials.keys().sorted() {
		credentials << MCPCredentialView{
			name:         name
			header_names: state.settings.credentials[name].keys().sorted()
		}
	}
	return MCPCredentialCatalog{
		path:        state.path
		credentials: credentials
	}
}

fn (mut state MCPCredentialState) get_headers(name string) !map[string]string {
	state.mu.lock()
	defer {
		state.mu.unlock()
	}
	if name !in state.settings.credentials {
		return error('MCP credential not found')
	}
	if name in state.unavailable {
		return error(state.secret_error)
	}
	return state.settings.credentials[name].clone()
}

fn (mut state MCPCredentialState) upsert(input MCPCredentialInput) !MCPCredentialView {
	state.mu.lock()
	defer {
		state.mu.unlock()
	}
	if !is_valid_mcp_credential_name(input.name) {
		return error('MCP credential name is invalid')
	}
	if input.headers.len == 0 {
		return error('MCP credential requires at least one header')
	}
	if input.headers.len > max_plugin_mcp_headers {
		return error('headers exceeds the ${max_plugin_mcp_headers} entry limit')
	}
	if state.settings.credentials.len >= max_mcp_credentials
		&& input.name !in state.settings.credentials {
		return error('MCP credential limit (${max_mcp_credentials}) reached')
	}
	mut headers := map[string]string{}
	for key, value in input.headers {
		if !valid_http_header(key, value) {
			return error('HTTP header is invalid')
		}
		for existing, _ in headers {
			if existing.to_lower() == key.to_lower() {
				return error('HTTP header names must be unique regardless of case')
			}
		}
		headers[key] = value
	}
	if state.mode == 'keychain' && state.path != '' {
		state.keychain_write_verified(mcp_credential_account(state.scope, input.name),
			json2.encode(headers)) or { return error(err.msg()) }
	}
	mut credentials := state.settings.credentials.clone()
	credentials[input.name] = headers
	updated := PersistedMCPCredentials{
		credentials: credentials
	}
	state.persist(updated)!
	state.settings = updated
	state.unavailable.delete(input.name)
	return MCPCredentialView{
		name:         input.name
		header_names: headers.keys().sorted()
	}
}

fn (mut state MCPCredentialState) remove(name string) ! {
	state.mu.lock()
	defer {
		state.mu.unlock()
	}
	if !is_valid_mcp_credential_name(name) {
		return error('MCP credential name is invalid')
	}
	if name !in state.settings.credentials {
		return error('MCP credential not found')
	}
	if state.mode == 'keychain' && state.path != '' {
		state.backend.delete(mcp_credential_account(state.scope, name)) or {
			return error(with_keychain_hint(err.msg()))
		}
	}
	mut credentials := state.settings.credentials.clone()
	credentials.delete(name)
	updated := PersistedMCPCredentials{
		credentials: credentials
	}
	state.persist(updated)!
	state.settings = updated
	state.unavailable.delete(name)
}

// persist writes the on-disk form: in keychain mode only header names are
// stored (values stay in the keychain); in file mode values are written to
// the owner-only file as before.
fn (state &MCPCredentialState) persist(settings PersistedMCPCredentials) ! {
	if state.path == '' {
		return
	}
	mut on_disk := settings
	if state.mode == 'keychain' {
		mut redacted := map[string]map[string]string{}
		for name, headers in settings.credentials {
			mut names_only := map[string]string{}
			for key, _ in headers {
				names_only[key] = ''
			}
			redacted[name] = names_only
		}
		on_disk = PersistedMCPCredentials{
			credentials: redacted
		}
	}
	ensure_directory(os.dir(state.path))!
	write_private_file_atomic(state.path, json2.encode(on_disk))!
}

fn decode_mcp_credential_input(raw string) !MCPCredentialInput {
	fields := json2.decode[map[string]json2.Any](raw) or {
		return error('Expected name and headers fields')
	}
	name_value := fields['name'] or { return error('Expected name field') }
	headers_value := fields['headers'] or { return error('Expected headers field') }
	if name_value !is string {
		return error('name must be a string')
	}
	if headers_value !is map[string]json2.Any {
		return error('headers must be an object of strings')
	}
	mut headers := map[string]string{}
	for key, value in headers_value as map[string]json2.Any {
		if value !is string {
			return error('headers must be an object of strings')
		}
		headers[key] = value as string
	}
	return MCPCredentialInput{
		name:    name_value as string
		headers: headers
	}
}

fn merge_mcp_credential_headers(literal map[string]string, credential map[string]string) !map[string]string {
	mut merged := map[string]string{}
	for key, value in credential {
		merged[key] = value
	}
	for key, value in literal {
		for existing, _ in merged {
			if existing.to_lower() == key.to_lower() && existing != key {
				return error('HTTP header names must be unique regardless of case')
			}
		}
		// Literal headers on the server config win over credential defaults.
		merged[key] = value
	}
	if merged.len > max_plugin_mcp_headers {
		return error('headers exceeds the ${max_plugin_mcp_headers} entry limit')
	}
	return merged
}
