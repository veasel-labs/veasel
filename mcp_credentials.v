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
}

fn new_mcp_credential_state(path string) &MCPCredentialState {
	mut state := &MCPCredentialState{
		path:     path
		settings: PersistedMCPCredentials{
			credentials: map[string]map[string]string{}
		}
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
				if valid_http_header(key, value) {
					cleaned[key] = value
				}
			}
			if cleaned.len > 0 {
				credentials[name] = cleaned
			}
		}
		state.settings.credentials = credentials
	}
	return state
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
	mut credentials := state.settings.credentials.clone()
	credentials[input.name] = headers
	updated := PersistedMCPCredentials{
		credentials: credentials
	}
	state.persist(updated)!
	state.settings = updated
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
	mut credentials := state.settings.credentials.clone()
	credentials.delete(name)
	updated := PersistedMCPCredentials{
		credentials: credentials
	}
	state.persist(updated)!
	state.settings = updated
}

fn (state &MCPCredentialState) persist(settings PersistedMCPCredentials) ! {
	if state.path == '' {
		return
	}
	os.mkdir_all(os.dir(state.path))!
	temporary_path := '${state.path}.tmp'
	write_private_file(temporary_path, json2.encode(settings))!
	$if !windows {
		os.chmod(temporary_path, 0o600)!
	}
	os.mv(temporary_path, state.path)!
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
