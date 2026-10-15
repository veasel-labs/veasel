module main

import os
import uuid

fn test_mcp_credential_upsert_list_remove_and_merge() {
	data_dir := os.join_path(os.temp_dir(), 'veasel-mcp-creds-${uuid.new_v4().str()}')
	os.mkdir_all(data_dir) or { panic(err) }
	defer {
		os.rmdir_all(data_dir) or {}
	}
	path := os.join_path(data_dir, 'mcp-credentials.json')
	mut state := new_mcp_credential_state(path)

	created := state.upsert(MCPCredentialInput{
		name:    'docs-token'
		headers: {
			'Authorization': 'Bearer vault-secret'
			'X-Tenant':      'acme'
		}
	}) or { panic(err) }
	assert created.name == 'docs-token'
	assert created.header_names == ['Authorization', 'X-Tenant']
	assert os.is_file(path)

	listed := state.view()
	assert listed.credentials.len == 1
	assert listed.credentials[0].header_names == ['Authorization', 'X-Tenant']

	headers := state.get_headers('docs-token') or { panic(err) }
	assert headers['Authorization'] == 'Bearer vault-secret'

	merged := merge_mcp_credential_headers({
		'Authorization': 'Bearer literal-wins'
		'X-Extra':       'yes'
	}, headers) or { panic(err) }
	assert merged['Authorization'] == 'Bearer literal-wins'
	assert merged['X-Tenant'] == 'acme'
	assert merged['X-Extra'] == 'yes'

	state.remove('docs-token') or { panic(err) }
	assert state.view().credentials.len == 0
	_ := state.get_headers('docs-token') or {
		assert err.msg() == 'MCP credential not found'
		return
	}
	assert false, 'removed credential must not resolve'
}

fn test_configured_mcp_http_resolves_named_credential() {
	data_dir := os.join_path(os.temp_dir(), 'veasel-mcp-cred-resolve-${uuid.new_v4().str()}')
	os.mkdir_all(data_dir) or { panic(err) }
	defer {
		os.rmdir_all(data_dir) or {}
	}
	mut store := open_store(os.join_path(data_dir, 'veasel.sqlite3')) or { panic(err) }
	defer {
		store.close() or {}
	}
	mut app := new_app(store, os.join_path(data_dir, 'plugins'))
	mut creds := app.mcp_credentials
	_ := creds.upsert(MCPCredentialInput{
		name:    'remote-auth'
		headers: {
			'Authorization': 'Bearer from-vault'
		}
	}) or { panic(err) }

	mut state := app.configured_mcp
	_ := state.upsert(ConfiguredMCPServerInput{
		name:       'docs-remote'
		transport:  'streamable-http'
		url:        'https://example.com/mcp'
		headers:    {
			'X-Client': 'veasel'
		}
		credential: 'remote-auth'
		enabled:    true
	}) or { panic(err) }

	view := state.view()
	remote := view.servers.filter(it.name == 'docs-remote')
	assert remote.len == 1
	assert remote[0].credential == 'remote-auth'
	assert remote[0].header_names == ['X-Client']

	server := app.get_configured_plugin_server(mut state, 'docs-remote') or { panic(err) }
	assert server.transport == 'streamable-http'
	assert server.headers['Authorization'] == 'Bearer from-vault'
	assert server.headers['X-Client'] == 'veasel'

	_, trusted := app.find_session_mcp_server(configured_mcp_plugin_name, 'docs-remote', '') or {
		panic(err)
	}
	assert trusted.headers['Authorization'] == 'Bearer from-vault'
}

fn test_mcp_credential_rejects_invalid_and_stdio_credential() {
	mut state := new_mcp_credential_state('')
	_ := state.upsert(MCPCredentialInput{
		name:    'bad name'
		headers: {
			'Authorization': 'Bearer x'
		}
	}) or {
		assert err.msg().contains('invalid')
		mut mcp := new_configured_mcp_state('')
		_ := mcp.upsert(ConfiguredMCPServerInput{
			name:       'stdio-with-cred'
			transport:  'stdio'
			command:    'true'
			credential: 'any'
			enabled:    true
		}) or {
			assert err.msg().contains('credential')
			return
		}
		assert false, 'stdio must reject credential'
		return
	}
	assert false, 'invalid credential name must fail'
}
