module main

import os
import uuid

fn test_plugin_component_names_reject_control_bytes() {
	assert is_valid_plugin_component_entry_name('local')
	assert !is_valid_plugin_component_entry_name('bad\tname')
	assert !is_valid_plugin_component_entry_name('bad\nname')
	assert !is_valid_plugin_component_entry_name('bad\0name')
	assert !is_valid_plugin_component_plugin_name('bad\tplugin')
	decode_plugin_component_toggle_input('{"plugin":"demo","kind":"mcp","name":"bad\\tname","enabled":false}') or {
		assert err.msg().contains('entry name is invalid')
		return
	}
	assert false, 'control bytes in component entry names must be rejected'
}

fn test_plugin_component_disable_persists_and_filters_catalog() {
	data_dir := os.join_path(os.temp_dir(), 'veasel-plugin-components-${uuid.new_v4().str()}')
	plugin_dir := os.join_path(data_dir, 'plugins')
	package_dir := os.join_path(plugin_dir, 'demo')
	os.mkdir_all(os.join_path(package_dir, 'skills', 'helper')) or { panic(err) }
	defer {
		os.rmdir_all(data_dir) or {}
	}
	os.write_file(os.join_path(package_dir, 'plugin.json'), '{"${plugin_schema_key}":"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json","name":"demo","version":"1","description":"demo"}') or {
		panic(err)
	}
	os.write_file(os.join_path(package_dir, 'skills', 'helper', 'SKILL.md'), '---\nname: helper\ndescription: Help\n---\nBody\n') or {
		panic(err)
	}
	os.write_file(os.join_path(package_dir, 'mcp.json'), '{"${plugin_schema_key}":"${plugin_mcp_schema}","mcpServers":{"local":{"type":"stdio","command":"true"}}}') or {
		panic(err)
	}
	mut store := open_store(os.join_path(data_dir, 'veasel.sqlite3')) or { panic(err) }
	defer {
		store.close() or {}
	}
	mut app := new_app(store, plugin_dir)
	before := app.plugin_catalog_for_directory('') or { panic(err) }
	demo := before.plugins.filter(it.name == 'demo')
	assert demo.len == 1
	assert demo[0].skills[0].enabled
	assert demo[0].mcp_servers[0].enabled

	mut state := app.plugin_components
	disabled := state.set_enabled(PluginComponentToggleInput{
		plugin:  'demo'
		kind:    plugin_component_kind_mcp
		name:    'local'
		enabled: false
	}) or { panic(err) }
	assert !disabled.enabled
	assert os.is_file(store.plugin_components_path())

	after := app.plugin_catalog_for_directory('') or { panic(err) }
	demo_after := after.plugins.filter(it.name == 'demo')
	assert demo_after.len == 1
	assert demo_after[0].skills[0].enabled
	assert !demo_after[0].mcp_servers[0].enabled

	_, _ := app.find_session_mcp_server('demo', 'local', '') or {
		assert err.msg().contains('disabled')
		_ := state.set_enabled(PluginComponentToggleInput{
			plugin:  'demo'
			kind:    plugin_component_kind_skill
			name:    'helper'
			enabled: false
		}) or { panic(err) }
		assert !state.is_enabled('demo', plugin_component_kind_skill, 'helper')
		return
	}
	assert false, 'disabled MCP component must not resolve for trust'
}
