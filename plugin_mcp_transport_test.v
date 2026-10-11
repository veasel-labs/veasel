module main

import json2
import mcp
import os
import uuid

fn test_plugin_mcp_data_persists_across_processes_and_environment_is_filtered() {
	node := os.find_abs_path_of_executable('node') or {
		if os.getenv('CI') == 'true' {
			panic('Node.js is required to run the MCP process fixture in CI')
		}
		return
	}
	root := os.join_path(os.temp_dir(), 'veasel-mcp-persistence-${uuid.new_v4().str()}')
	data := os.join_path(os.temp_dir(), 'veasel-mcp-data-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
		os.rmdir_all(data) or {}
	}
	secret_name := 'VEASEL_PLUGIN_TEST_SECRET'
	previous_secret := os.getenv_opt(secret_name)
	assert os.setenv(secret_name, 'host-only-secret', true) == 0
	defer {
		if secret := previous_secret {
			os.setenv(secret_name, secret, true)
		} else {
			os.unsetenv(secret_name)
		}
	}
	script := os.join_path(root, 'fixture.mjs')
	fixture := "import readline from 'node:readline';\n" +
		"import { readFileSync, writeFileSync } from 'node:fs';\n" +
		"import { join } from 'node:path';\n" +
		'const lines = readline.createInterface({ input: process.stdin });\n' +
		'for await (const line of lines) {\n' +
		'  const request = JSON.parse(line);\n' +
		'  if (!request.id) continue;\n' +
		'  let result;\n' +
		"  if (request.method === 'initialize') result = { protocolVersion: '2025-11-25', capabilities: { tools: {} }, serverInfo: { name: 'fixture', version: '1.0.0' } };\n" +
		"  else if (request.method === 'tools/list') result = { tools: [{ name: 'persist', description: 'Write or read plugin data.', inputSchema: { type: 'object', properties: { action: { type: 'string' } }, required: ['action'], additionalProperties: false } }] };\n" +
		"  else if (request.method === 'tools/call') { const action = request.params.arguments.action; const state = join(process.env.PLUGIN_DATA, 'state.txt'); if (action === 'write') writeFileSync(state, 'survives-restart'); const persisted = action === 'read' ? readFileSync(state, 'utf8') : 'written'; result = { content: [{ type: 'text', text: [process.env.PLUGIN_ROOT, process.env.PLUGIN_DATA, process.env.VEASEL_PLUGIN_TEST_SECRET || 'filtered', persisted].join('|') }], isError: false }; }\n" +
		'  else result = {};\n' +
		"  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result }) + '\\n');\n" +
		'}\n'
	os.write_file(script, fixture) or { panic(err) }
	server := PluginMCPServer{
		name:      'fixture'
		transport: 'stdio'
		command:   node
		args:      [script]
		cwd:       './'
	}
	first_write := plugin_mcp_persistence_call(root, data, server, 'write')
	$if !windows {
		info := os.stat(data) or { panic(err) }
		assert info.mode & 0o777 == 0o700
	}
	second_read := plugin_mcp_persistence_call(root, data, server, 'read')
	root_expected := os.real_path(root)
	data_expected := os.real_path(data)
	assert first_write.contains(root_expected)
	assert first_write.contains(data_expected)
	assert first_write.contains('filtered')
	assert !first_write.contains('host-only-secret')
	assert second_read.contains('survives-restart')
	assert second_read.contains('filtered')
	assert !second_read.contains('host-only-secret')
}

fn plugin_mcp_persistence_call(root string, data string, server PluginMCPServer, action string) string {
	mut client := new_plugin_mcp_client(root, data, server) or { panic(err) }
	defer {
		client.close()
	}
	client.initialize() or { panic(err) }
	arguments := json2.decode[json2.Any]('{"action":"${action}"}') or { panic(err) }
	response := client.request_message('tools/call', {
		'name':      json2.Any('persist')
		'arguments': arguments
	}) or { panic(err) }
	assert response.error.code == 0
	result := json2.decode[json2.Any](response.result) or { panic(err) }
	content := result.as_map()['content'] or { panic('MCP tool returned no content') }
	items := content.as_array()
	assert items.len == 1
	text := items[0].as_map()['text'] or { panic('MCP tool returned no text') }
	return text.str()
}

fn test_plugin_stdio_mcp_process_environment_handshake_and_tool_call() {
	node := os.find_abs_path_of_executable('node') or {
		if os.getenv('CI') == 'true' {
			panic('Node.js is required to run the MCP process fixture in CI')
		}
		return
	}
	root := os.join_path(os.temp_dir(), 'veasel-mcp-plugin-${os.getpid()}')
	data := os.join_path(os.temp_dir(), 'veasel-mcp-data-${os.getpid()}')
	os.mkdir_all(root) or { panic(err) }
	os.mkdir_all(data) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
		os.rmdir_all(data) or {}
	}
	script := os.join_path(root, 'fixture.mjs')
	fixture := "import readline from 'node:readline';\n" +
		'const lines = readline.createInterface({ input: process.stdin });\n' +
		'for await (const line of lines) {\n' +
		'  const request = JSON.parse(line);\n' +
		'  if (!request.id) continue;\n' +
		'  let result;\n' +
		"  if (request.method === 'initialize') result = { protocolVersion: '2025-11-25', capabilities: { tools: {} }, serverInfo: { name: 'fixture', version: '1.0.0' } };\n" +
		"  else if (request.method === 'tools/list') result = { tools: [{ name: 'inspect_environment', description: 'Return configured roots.', inputSchema: { type: 'object', properties: {}, additionalProperties: false } }] };\n" +
		"  else if (request.method === 'tools/call') result = { content: [{ type: 'text', text: [process.env.PLUGIN_ROOT, process.env.PLUGIN_DATA, process.cwd()].join('|') }], isError: false };\n" +
		'  else result = {};\n' +
		"  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result }) + '\\n');\n" +
		'}\n'
	os.write_file(script, fixture) or { panic(err) }
	server := PluginMCPServer{
		name:      'fixture'
		transport: 'stdio'
		command:   node
		args:      [script]
		cwd:       './'
	}
	mut client := new_plugin_mcp_client(root, data, server) or { panic(err) }
	defer {
		client.close()
	}
	client.initialize() or { panic(err) }
	listed := client.request_message('tools/list', mcp.empty_object) or { panic(err) }
	assert listed.error.code == 0
	assert listed.result.contains('inspect_environment')
	arguments := json2.decode[json2.Any]('{}') or { panic(err) }
	response := client.request_message('tools/call', {
		'name':      json2.Any('inspect_environment')
		'arguments': arguments
	}) or { panic(err) }
	assert response.error.code == 0
	expected := '${os.real_path(root)}|${os.real_path(data)}|${os.real_path(root)}'
	encoded := json2.encode(expected).to_lower()
	encoded_expected := encoded[1..encoded.len - 1]
	assert response.result.to_lower().contains(encoded_expected)
}

fn test_trusted_session_mcp_tool_discovery_and_dispatch_keep_turn_state() {
	node := os.find_abs_path_of_executable('node') or {
		if os.getenv('CI') == 'true' {
			panic('Node.js is required to run the MCP process fixture in CI')
		}
		return
	}
	root := os.join_path(os.temp_dir(), 'veasel-mcp-runtime-${uuid.new_v4().str()}')
	plugin_directory := os.join_path(root, 'plugins')
	package_directory := os.join_path(plugin_directory, 'fixture')
	os.mkdir_all(package_directory) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	manifest := '{"' + plugin_schema_key + '":"' + plugin_manifest_schema + '","name":"fixture-tools"}'
	os.write_file(os.join_path(package_directory, 'plugin.json'), manifest) or { panic(err) }
	script := "import readline from 'node:readline';\n" +
		'let calls = 0;\n' +
		'const lines = readline.createInterface({ input: process.stdin });\n' +
		'for await (const line of lines) {\n' +
		'  const request = JSON.parse(line);\n' +
		'  if (!request.id) continue;\n' +
		'  let result;\n' +
		"  if (request.method === 'initialize') result = { protocolVersion: '2025-11-25', capabilities: { tools: {} }, serverInfo: { name: 'fixture', version: '1.0.0' } };\n" +
		"  else if (request.method === 'tools/list' && request.params?.cursor === 'page-2') result = { tools: [{ name: 'count_calls_second_page', description: 'Second page fixture.', inputSchema: { type: 'object', properties: {}, additionalProperties: false } }] };\n" +
		"  else if (request.method === 'tools/list') result = { tools: [{ name: 'count_calls', description: 'Count calls during one turn.', inputSchema: { type: 'object', properties: {}, additionalProperties: false } }], nextCursor: 'page-2' };\n" +
		"  else if (request.method === 'tools/call') result = { content: [{ type: 'text', text: String(++calls) }], isError: false };\n" +
		'  else result = {};\n' +
		"  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result }) + '\\n');\n" +
		'}\n'
	os.write_file(os.join_path(package_directory, 'fixture.mjs'), script) or { panic(err) }
	root_placeholder := '$' + '{PLUGIN_ROOT}/fixture.mjs'
	mcp_config := '{"' + plugin_schema_key + '":"' + plugin_mcp_schema + '","mcpServers":{"local":{"type":"stdio","command":"node","args":["' + root_placeholder + '"],"cwd":"./"}}}'
	os.write_file(os.join_path(package_directory, 'mcp.json'), mcp_config) or { panic(err) }
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{
		title:     'MCP runtime fixture'
		directory: root
	}) or { panic(err) }
	store.set_session_plugin_mcp_server(session.id, 'fixture-tools', 'local', true) or {
		panic(err)
	}
	mut app := new_app(store, plugin_directory)
	defer { app.close() }
	definitions, bindings, mut connections := app.load_session_plugin_mcp_tools(session.id) or {
		panic(err)
	}
	defer { close_plugin_mcp_connections(mut connections) }
	assert definitions.len == 2
	assert connections.len == 1
	binding := bindings[definitions[0].name]
	first := execute_plugin_mcp_tool(mut connections, binding, '{}')
	second := execute_plugin_mcp_tool(mut connections, binding, '{}')
	second_page_binding := bindings[definitions[1].name]
	third := execute_plugin_mcp_tool(mut connections, second_page_binding, '{}')
	assert first.contains('"text":"1"')
	assert second.contains('"text":"2"')
	assert third.contains('"text":"3"')
}
