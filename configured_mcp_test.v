module main

import os
import uuid

fn test_configured_mcp_upsert_list_enable_remove_and_catalog() {
	data_dir := os.join_path(os.temp_dir(), 'veasel-configured-mcp-${uuid.new_v4().str()}')
	os.mkdir_all(data_dir) or { panic(err) }
	defer {
		os.rmdir_all(data_dir) or {}
	}
	path := os.join_path(data_dir, 'mcp-servers.json')
	mut state := new_configured_mcp_state(path)

	stdio := state.upsert(ConfiguredMCPServerInput{
		name:      'echo-tools'
		transport: 'stdio'
		command:   'true'
		args:      ['--noop']
		enabled:   true
	}) or { panic(err) }
	assert stdio.name == 'echo-tools'
	assert stdio.enabled
	assert stdio.scope == 'user'
	assert stdio.transport == 'stdio'
	assert stdio.command == 'true'
	assert stdio.args == ['--noop']

	http := state.upsert(ConfiguredMCPServerInput{
		name:      'docs-remote'
		transport: 'streamable-http'
		url:       'https://example.com/mcp'
		headers:   {
			'Authorization': 'Bearer secret'
		}
		enabled:   true
	}) or { panic(err) }
	assert http.url_origin == 'https://example.com'
	assert http.header_names == ['Authorization']
	assert os.is_file(path)

	listed := state.view()
	assert listed.scope == 'user'
	assert listed.servers.len == 2
	assert listed.servers[0].name == 'docs-remote'
	assert listed.servers[1].name == 'echo-tools'

	disabled := state.set_enabled('echo-tools', false) or { panic(err) }
	assert !disabled.enabled
	assert state.list_plugin_servers().len == 1
	assert state.list_plugin_servers()[0].name == 'docs-remote'
	_ := state.get_plugin_server('echo-tools') or {
		assert err.msg().contains('disabled')
		reloaded := new_configured_mcp_state(path)
		assert reloaded.view().servers.len == 2
		assert !reloaded.view().servers.filter(it.name == 'echo-tools')[0].enabled
		_ := reloaded.set_enabled('echo-tools', true) or { panic(err) }
		catalog := merge_configured_mcp_into_catalog(PluginCatalog{}, reloaded.list_plugin_servers())
		assert catalog.plugins.len == 1
		assert catalog.plugins[0].name == configured_mcp_plugin_name
		assert catalog.plugins[0].origin == 'configured'
		assert catalog.plugins[0].mcp_servers.len == 2
		reloaded.remove('docs-remote') or { panic(err) }
		assert reloaded.view().servers.len == 1
		return
	}
	assert false, 'disabled configured MCP server must not resolve for trust'
}

fn test_configured_mcp_rejects_unsafe_stdio_and_reserved_name() {
	mut state := new_configured_mcp_state('')
	_ := state.upsert(ConfiguredMCPServerInput{
		name:      configured_mcp_plugin_name
		transport: 'stdio'
		command:   'true'
	}) or {
		assert err.msg().contains('invalid')
		_ := state.upsert(ConfiguredMCPServerInput{
			name:      'relative-cmd'
			transport: 'stdio'
			command:   './bin/server'
		}) or {
			assert err.msg().contains('bare name or absolute')
			_ := state.upsert(ConfiguredMCPServerInput{
				name:      'bad-cwd'
				transport: 'stdio'
				command:   'true'
				cwd:       'relative'
			}) or {
				assert err.msg().contains('absolute')
				return
			}
			assert false, 'relative cwd must be rejected'
			return
		}
		assert false, 'relative command must be rejected'
		return
	}
	assert false, 'reserved configured name must be rejected'
}

fn test_find_session_mcp_server_promotes_absolute_cwd() {
	data_dir := os.join_path(os.temp_dir(), 'veasel-configured-mcp-cwd-${uuid.new_v4().str()}')
	plugin_dir := os.join_path(data_dir, 'plugins')
	os.mkdir_all(plugin_dir) or { panic(err) }
	defer {
		os.rmdir_all(data_dir) or {}
	}
	cwd := os.join_path(data_dir, 'work')
	os.mkdir_all(cwd) or { panic(err) }
	mut store := open_store(os.join_path(data_dir, 'veasel.sqlite3')) or { panic(err) }
	defer {
		store.close() or {}
	}
	mut app := new_app(store, plugin_dir)
	mut state := app.configured_mcp
	_ := state.upsert(ConfiguredMCPServerInput{
		name:      'cwd-server'
		transport: 'stdio'
		command:   'true'
		cwd:       cwd
	}) or { panic(err) }
	root, server := app.find_session_mcp_server(configured_mcp_plugin_name, 'cwd-server', '') or {
		panic(err)
	}
	assert root == cwd
	assert server.cwd == ''
	assert server.command == 'true'
}

fn test_project_configured_mcp_overrides_user_in_catalog_and_trust() {
	data_dir := os.join_path(os.temp_dir(), 'veasel-configured-mcp-project-${uuid.new_v4().str()}')
	plugin_dir := os.join_path(data_dir, 'plugins')
	workspace := os.join_path(data_dir, 'workspace')
	os.mkdir_all(plugin_dir) or { panic(err) }
	os.mkdir_all(workspace) or { panic(err) }
	defer {
		os.rmdir_all(data_dir) or {}
	}
	mut store := open_store(os.join_path(data_dir, 'veasel.sqlite3')) or { panic(err) }
	defer {
		store.close() or {}
	}
	mut app := new_app(store, plugin_dir)
	mut user_state := app.configured_mcp
	_ := user_state.upsert(ConfiguredMCPServerInput{
		name:      'shared'
		transport: 'stdio'
		command:   'true'
		args:      ['--user']
	}) or { panic(err) }
	mut project_state := app.configured_mcp_state_for_scope(configured_mcp_scope_project, workspace) or {
		panic(err)
	}
	project_view := project_state.upsert_scoped(ConfiguredMCPServerInput{
		name:      'shared'
		transport: 'stdio'
		command:   'true'
		args:      ['--project']
		scope:     configured_mcp_scope_project
		directory: workspace
	}, configured_mcp_scope_project) or { panic(err) }
	assert project_view.scope == configured_mcp_scope_project
	assert os.is_file(project_configured_mcp_path(workspace))

	listed := app.list_configured_mcp_catalog(workspace)
	assert listed.scope == 'mixed'
	assert listed.project_path == project_configured_mcp_path(workspace)
	assert listed.servers.len == 2
	assert listed.servers.filter(it.scope == configured_mcp_scope_user).len == 1
	assert listed.servers.filter(it.scope == configured_mcp_scope_project).len == 1

	catalog := app.plugin_catalog_for_directory(workspace) or { panic(err) }
	configured := catalog.plugins.filter(it.name == configured_mcp_plugin_name)
	assert configured.len == 1
	assert configured[0].mcp_servers.len == 1
	assert configured[0].mcp_servers[0].name == 'shared'
	// Project wins for the synthetic catalog entry used at trust time.
	_, server := app.find_session_mcp_server(configured_mcp_plugin_name, 'shared', workspace) or {
		panic(err)
	}
	assert server.args == ['--project']
}

fn test_imported_mcp_json_overlays_user_and_loses_to_project() {
	data_dir := os.join_path(os.temp_dir(), 'veasel-configured-mcp-import-${uuid.new_v4().str()}')
	plugin_dir := os.join_path(data_dir, 'plugins')
	workspace := os.join_path(data_dir, 'workspace')
	os.mkdir_all(plugin_dir) or { panic(err) }
	os.mkdir_all(workspace) or { panic(err) }
	defer {
		os.rmdir_all(data_dir) or {}
	}
	mut store := open_store(os.join_path(data_dir, 'veasel.sqlite3')) or { panic(err) }
	defer {
		store.close() or {}
	}
	mut app := new_app(store, plugin_dir)
	mut user_state := app.configured_mcp
	_ := user_state.upsert(ConfiguredMCPServerInput{
		name:      'shared'
		transport: 'stdio'
		command:   'true'
		args:      ['--user']
	}) or { panic(err) }
	placeholder := r'${workspaceFolder}/x'
	os.write_file(os.join_path(workspace, configured_mcp_import_mcp_json), '{
		"mcpServers": {
			"shared": { "command": "true", "args": ["--imported"] },
			"docs": { "type": "http", "url": "https://example.com/mcp" },
			"skipped": { "command": "true", "args": ["' + placeholder + '"] }
		}
	}') or { panic(err) }
	os.mkdir_all(os.join_path(workspace, '.cursor')) or { panic(err) }
	os.write_file(os.join_path(workspace, configured_mcp_import_cursor), '{
		"mcpServers": {
			"shared": { "command": "true", "args": ["--cursor"] },
			"cursor-only": { "command": "true", "args": ["--cursor-only"] }
		}
	}') or { panic(err) }

	listed := app.list_configured_mcp_catalog(workspace)
	assert listed.scope == 'mixed'
	assert listed.import_paths.len == 2
	assert listed.servers.filter(it.scope == configured_mcp_scope_project_import).len >= 3
	assert listed.servers.filter(it.name == 'skipped').len == 0

	catalog := app.plugin_catalog_for_directory(workspace) or { panic(err) }
	configured := catalog.plugins.filter(it.name == configured_mcp_plugin_name)
	assert configured.len == 1
	names := configured[0].mcp_servers.map(it.name)
	assert 'shared' in names
	assert 'docs' in names
	assert 'cursor-only' in names
	assert 'skipped' !in names

	_, imported := app.find_session_mcp_server(configured_mcp_plugin_name, 'shared', workspace) or {
		panic(err)
	}
	// Portable .mcp.json beats .cursor/mcp.json and user scope.
	assert imported.args == ['--imported']

	mut project_state := app.configured_mcp_state_for_scope(configured_mcp_scope_project, workspace) or {
		panic(err)
	}
	_ := project_state.upsert_scoped(ConfiguredMCPServerInput{
		name:      'shared'
		transport: 'stdio'
		command:   'true'
		args:      ['--project']
		scope:     configured_mcp_scope_project
		directory: workspace
	}, configured_mcp_scope_project) or { panic(err) }
	_, project := app.find_session_mcp_server(configured_mcp_plugin_name, 'shared', workspace) or {
		panic(err)
	}
	assert project.args == ['--project']
}
