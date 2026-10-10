module main

import json2
import mcp
import os
import uuid

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
	mut client, _ := new_plugin_mcp_client(root, data, server) or { panic(err) }
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
	assert response.result.contains('${os.real_path(root)}|${os.real_path(data)}|${os.real_path(root)}')
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
