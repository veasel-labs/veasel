module main

import json2
import mcp
import os
import strings
import time
import uuid

fn test_overlay_plugin_environment_replaces_case_variants_only_when_asked() {
	base := {
		'PATH': '/usr/bin'
		'HOME': '/home/a'
	}
	configured := {
		'Path': '/plugin/bin'
	}
	exact := overlay_plugin_environment(base, configured, false)
	assert exact['PATH'] == '/usr/bin'
	assert exact['Path'] == '/plugin/bin'
	assert exact['HOME'] == '/home/a'
	folded := overlay_plugin_environment(base, configured, true)
	assert folded['Path'] == '/plugin/bin'
	assert 'PATH' !in folded
	assert folded['HOME'] == '/home/a'
}

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
		"  else if (request.method === 'tools/call') { const action = request.params.arguments.action; const state = join(process.env.PLUGIN_DATA, 'state.txt'); if (action === 'write') writeFileSync(state, 'survives-restart'); const persisted = action === 'read' ? readFileSync(state, 'utf8') : 'written'; result = { content: [{ type: 'text', text: [process.env.PLUGIN_ROOT, process.env.PLUGIN_DATA, process.cwd(), process.env.VEASEL_PLUGIN_TEST_ROOT, process.env.VEASEL_PLUGIN_TEST_DATA, process.env.VEASEL_PLUGIN_TEST_SECRET || 'filtered', persisted].join('|') }], isError: false }; }\n" +
		'  else result = {};\n' +
		"  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result }) + '\\n');\n" +
		'}\n'
	os.write_file(script, fixture) or { panic(err) }
	root_placeholder := '$' + '{PLUGIN_ROOT}'
	data_placeholder := '$' + '{PLUGIN_DATA}'
	server := PluginMCPServer{
		name:      'fixture'
		transport: 'stdio'
		command:   node
		args:      ['${root_placeholder}/fixture.mjs']
		env:       {
			'VEASEL_PLUGIN_TEST_ROOT': '${root_placeholder}/from-env'
			'VEASEL_PLUGIN_TEST_DATA': '${data_placeholder}/from-env'
		}
		cwd:       data_placeholder
	}
	first_write := plugin_mcp_persistence_call(root, data, server, 'write')
	$if !windows {
		info := os.stat(data) or { panic(err) }
		assert info.mode & 0o777 == 0o700
	}
	second_read := plugin_mcp_persistence_call(root, data, server, 'read')
	root_expected := os.real_path(root)
	data_expected := os.real_path(data)
	root_env_expected := root_expected + '/from-env'
	data_env_expected := data_expected + '/from-env'
	first_values := first_write.split('|')
	assert first_values.len == 7
	assert first_values[0] == root_expected
	assert first_values[1] == data_expected
	assert first_values[2] == data_expected
	assert first_values[3] == root_env_expected
	assert first_values[4] == data_env_expected
	assert first_values[5] == 'filtered'
	assert first_values[6] == 'written'
	second_values := second_read.split('|')
	assert second_values.len == 7
	assert second_values[0] == root_expected
	assert second_values[1] == data_expected
	assert second_values[2] == data_expected
	assert second_values[3] == root_env_expected
	assert second_values[4] == data_env_expected
	assert second_values[5] == 'filtered'
	assert second_values[6] == 'survives-restart'
	os.write_file(script, fixture + '\n// package files replaced\n') or { panic(err) }
	third_read := plugin_mcp_persistence_call(root, data, server, 'read')
	third_values := third_read.split('|')
	assert third_values.len == 7
	assert third_values[0] == root_expected
	assert third_values[1] == data_expected
	assert third_values[6] == 'survives-restart'
}

fn plugin_mcp_persistence_call(root string, data string, server PluginMCPServer, action string) string {
	mut client := new_plugin_mcp_fixture_client(root, data, server) or { panic(err) }
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

// Protocol fixtures use host-installed runtimes; only the dedicated sandbox
// test below exercises the fail-closed wrapper itself.
fn with_mcp_fixture_sandbox_off[T](start fn () !T) !T {
	prior := os.getenv_opt(mcp_stdio_sandbox_mode_env)
	prior_opt_in := os.getenv_opt(shell_sandbox_opt_in_env)
	os.setenv(mcp_stdio_sandbox_mode_env, 'off', true)
	os.setenv(shell_sandbox_opt_in_env, shell_unsandboxed_opt_in_token, true)
	defer {
		if value := prior {
			os.setenv(mcp_stdio_sandbox_mode_env, value, true)
		} else {
			os.unsetenv(mcp_stdio_sandbox_mode_env)
		}
		if value := prior_opt_in {
			os.setenv(shell_sandbox_opt_in_env, value, true)
		} else {
			os.unsetenv(shell_sandbox_opt_in_env)
		}
	}
	return start()!
}

fn new_plugin_mcp_fixture_client(root string, data string, server PluginMCPServer) !mcp.Client {
	return with_mcp_fixture_sandbox_off(fn [root, data, server] () !mcp.Client {
		return new_plugin_mcp_client(root, data, server)
	})
}

fn start_plugin_mcp_fixture_transport(root string, data string, server PluginMCPServer) !&PluginMCPTransport {
	return with_mcp_fixture_sandbox_off(fn [root, data, server] () !&PluginMCPTransport {
		return start_plugin_mcp_transport(root, data, server)
	})
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
	mut client := new_plugin_mcp_fixture_client(root, data, server) or { panic(err) }
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
	prior_sandbox_mode := os.getenv_opt(mcp_stdio_sandbox_mode_env)
	prior_opt_in := os.getenv_opt(shell_sandbox_opt_in_env)
	os.setenv(mcp_stdio_sandbox_mode_env, 'off', true)
	os.setenv(shell_sandbox_opt_in_env, shell_unsandboxed_opt_in_token, true)
	defer {
		if value := prior_sandbox_mode {
			os.setenv(mcp_stdio_sandbox_mode_env, value, true)
		} else {
			os.unsetenv(mcp_stdio_sandbox_mode_env)
		}
		if value := prior_opt_in {
			os.setenv(shell_sandbox_opt_in_env, value, true)
		} else {
			os.unsetenv(shell_sandbox_opt_in_env)
		}
	}
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

fn bad_mcp_server(node string, script string) PluginMCPServer {
	return PluginMCPServer{
		name:      'fixture'
		transport: 'stdio'
		command:   node
		args:      [script]
		cwd:       './'
	}
}

fn mcp_bad_fixture_root(tag string) (string, string) {
	root := os.join_path(os.temp_dir(), 'veasel-mcp-${tag}-${os.getpid()}')
	data := os.join_path(os.temp_dir(), 'veasel-mcp-${tag}-data-${os.getpid()}')
	os.mkdir_all(root) or { panic(err) }
	os.mkdir_all(data) or { panic(err) }
	return root, data
}

fn require_node_for_mcp_fixture() string {
	return os.find_abs_path_of_executable('node') or {
		if os.getenv('CI') == 'true' {
			panic('Node.js is required to run the MCP process fixture in CI')
		}
		return ''
	}
}

fn test_plugin_stdio_mcp_malformed_frame_fails_initialize() {
	node := require_node_for_mcp_fixture()
	if node.len == 0 {
		return
	}
	root, data := mcp_bad_fixture_root('malformed')
	defer {
		os.rmdir_all(root) or {}
		os.rmdir_all(data) or {}
	}
	script := os.join_path(root, 'fixture.mjs')
	os.write_file(script, "import readline from 'node:readline';\n" +
		'const lines = readline.createInterface({ input: process.stdin });\n' +
		"for await (const line of lines) { process.stdout.write('this is not json\\n'); }\n") or {
		panic(err)
	}
	mut client := new_plugin_mcp_fixture_client(root, data, bad_mcp_server(node, script)) or { panic(err) }
	defer { client.close() }
	mut failed := false
	client.initialize() or { failed = true }
	assert failed
}

fn test_plugin_stdio_mcp_oversized_frame_fails_receive() {
	node := require_node_for_mcp_fixture()
	if node.len == 0 {
		return
	}
	root, data := mcp_bad_fixture_root('oversized')
	defer {
		os.rmdir_all(root) or {}
		os.rmdir_all(data) or {}
	}
	script := os.join_path(root, 'fixture.mjs')
	os.write_file(script, "import readline from 'node:readline';\n" +
		'const lines = readline.createInterface({ input: process.stdin });\n' +
		"for await (const line of lines) { process.stdout.write('x'.repeat(1000001) + '\\n'); }\n") or {
		panic(err)
	}
	mut transport := start_plugin_mcp_fixture_transport(root, data, bad_mcp_server(node, script)) or {
		panic(err)
	}
	defer { transport.close() }
	transport.send('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}') or { panic(err) }
	mut message := ''
	transport.receive() or { message = err.msg() }
	assert message.contains('frame size limit')
}

fn test_plugin_stdio_mcp_silent_server_times_out() {
	node := require_node_for_mcp_fixture()
	if node.len == 0 {
		return
	}
	root, data := mcp_bad_fixture_root('silent')
	defer {
		os.rmdir_all(root) or {}
		os.rmdir_all(data) or {}
	}
	script := os.join_path(root, 'fixture.mjs')
	os.write_file(script, "import readline from 'node:readline';\n" +
		'const lines = readline.createInterface({ input: process.stdin });\n' +
		'for await (const line of lines) { }\n') or { panic(err) }
	mut transport := start_plugin_mcp_fixture_transport(root, data, bad_mcp_server(node, script)) or {
		panic(err)
	}
	defer { transport.close() }
	transport.response_timeout = 300 * time.millisecond
	transport.send('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}') or { panic(err) }
	started := time.now()
	mut message := ''
	transport.receive() or { message = err.msg() }
	assert message.contains('timed out')
	assert time.since(started) < 10 * time.second
}

fn test_plugin_stdio_mcp_cancel_sends_notifications_cancelled() {
	node := require_node_for_mcp_fixture()
	if node.len == 0 {
		return
	}
	root, data := mcp_bad_fixture_root('cancel-notify')
	defer {
		os.rmdir_all(root) or {}
		os.rmdir_all(data) or {}
	}
	script := os.join_path(root, 'fixture.mjs')
	os.write_file(script, "import readline from 'node:readline';\n" +
		'const lines = readline.createInterface({ input: process.stdin });\n' +
		'for await (const line of lines) {\n' +
		"  if (line.includes('notifications/cancelled')) {\n" +
		"    process.stdout.write(JSON.stringify({ ok: true }) + '\\n');\n" +
		'    break;\n' +
		'  }\n' +
		'}\n') or { panic(err) }
	mut transport := start_plugin_mcp_fixture_transport(root, data, bad_mcp_server(node, script)) or {
		panic(err)
	}
	defer {
		transport.close()
	}
	transport.response_timeout = 5 * time.second
	transport.send('{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"slow"}}') or {
		panic(err)
	}
	assert transport.active_request_id == '42'
	spawn fn (mut transport PluginMCPTransport) {
		time.sleep(100 * time.millisecond)
		transport.request_cancel()
	}(mut transport)
	frame := transport.receive() or {
		assert err.msg() == 'cancelled'
		assert transport.cancelled_notified
		return
	}
	assert false, 'expected cancel before frame, got ${frame}'
}

fn test_mcp_stdio_review_sandbox_preview_defaults_fail_closed() {
	prior := os.getenv_opt(mcp_stdio_sandbox_mode_env)
	defer {
		if value := prior {
			os.setenv(mcp_stdio_sandbox_mode_env, value, true)
		} else {
			os.unsetenv(mcp_stdio_sandbox_mode_env)
		}
	}
	os.unsetenv(mcp_stdio_sandbox_mode_env)
	preview := mcp_stdio_review_sandbox_preview()
	assert preview.mode == 'require'
	if mcp_stdio_sandbox_bubblewrap_capability() {
		assert preview.will_wrap
		assert preview.backend == 'bubblewrap'
		assert preview.network == 'shared'
	} else if mcp_stdio_sandbox_seatbelt_capability() {
		assert preview.will_wrap
		assert preview.backend == 'seatbelt'
		assert preview.network == 'shared'
	} else if mcp_stdio_sandbox_windows_capability() {
		assert preview.will_wrap
		assert preview.backend == 'windows'
		assert preview.network == 'shared'
	} else {
		assert !preview.will_wrap
		assert preview.backend == 'none'
		assert preview.network == 'none'
		assert !preview.unsandboxed
	}
	assert os.setenv(mcp_stdio_sandbox_mode_env, 'auto', true) == 0
	auto := mcp_stdio_review_sandbox_preview()
	assert auto.mode == 'auto'
	if mcp_stdio_sandbox_bubblewrap_capability() {
		assert auto.will_wrap
		assert auto.backend == 'bubblewrap'
		assert auto.network == 'shared'
	} else if mcp_stdio_sandbox_seatbelt_capability() {
		assert auto.will_wrap
		assert auto.backend == 'seatbelt'
		assert auto.network == 'shared'
	} else if mcp_stdio_sandbox_windows_capability() {
		assert auto.will_wrap
		assert auto.backend == 'windows'
		assert auto.network == 'shared'
	} else {
		assert !auto.will_wrap
		assert auto.backend == 'none'
		assert auto.network == 'none'
		assert !auto.unsandboxed
	}
}

fn test_mcp_stdio_invalid_sandbox_mode_fails_closed() {
	prior := os.getenv_opt(mcp_stdio_sandbox_mode_env)
	defer {
		if value := prior {
			os.setenv(mcp_stdio_sandbox_mode_env, value, true)
		} else {
			os.unsetenv(mcp_stdio_sandbox_mode_env)
		}
	}
	assert os.setenv(mcp_stdio_sandbox_mode_env, 'typo', true) == 0
	assert mcp_stdio_sandbox_mode() == .require
}

fn test_mcp_stdio_sandbox_default_fails_closed_without_backend_or_wraps_when_present() {
	prior := os.getenv_opt(mcp_stdio_sandbox_mode_env)
	assert os.unsetenv(mcp_stdio_sandbox_mode_env) == 0
	defer {
		if value := prior {
			os.setenv(mcp_stdio_sandbox_mode_env, value, true)
		} else {
			os.unsetenv(mcp_stdio_sandbox_mode_env)
		}
	}
	assert mcp_stdio_sandbox_mode() == .require
	$if linux {
		assert mcp_stdio_sandbox_bubblewrap_capability() == bubblewrap_available()
		assert !mcp_stdio_sandbox_seatbelt_capability()
		assert !mcp_stdio_sandbox_windows_capability()
		if bubblewrap_available() {
			node := if os.is_file('/usr/bin/node') { '/usr/bin/node' } else { return }
			root := os.join_path(os.temp_dir(), 'veasel-mcp-sandbox-${uuid.new_v4().str()}')
			data := os.join_path(os.temp_dir(), 'veasel-mcp-sandbox-data-${uuid.new_v4().str()}')
			os.mkdir_all(root) or { panic(err) }
			defer {
				os.rmdir_all(root) or {}
				os.rmdir_all(data) or {}
			}
			script := os.join_path(root, 'echo.mjs')
			os.write_file(script, "import readline from 'node:readline';\nconst lines = readline.createInterface({ input: process.stdin });\nfor await (const line of lines) {\n  const request = JSON.parse(line);\n  if (!request.id) continue;\n  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result: { ok: true, sandboxed: true } }) + '\\n');\n}\n") or {
				panic(err)
			}
			mut transport := start_plugin_mcp_transport(root, data, PluginMCPServer{
				name:      'sandbox-fixture'
				transport: 'stdio'
				command:   node
				args:      [script]
			}) or { panic(err) }
			defer {
				transport.close()
			}
			assert transport.mcp_stdio_alive()
			transport.send('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}') or {
				panic(err)
			}
			frame := transport.receive() or { panic(err) }
			assert frame.contains('"id":1')
			assert frame.contains('"sandboxed":true')
		}
	} $else $if macos {
		assert !mcp_stdio_sandbox_bubblewrap_capability()
		assert mcp_stdio_sandbox_seatbelt_capability() == seatbelt_available()
		assert !mcp_stdio_sandbox_windows_capability()
		if seatbelt_available() {
			node := os.find_abs_path_of_executable('node') or { return }
			root := os.join_path(os.temp_dir(), 'veasel-mcp-sandbox-${uuid.new_v4().str()}')
			data := os.join_path(os.temp_dir(), 'veasel-mcp-sandbox-data-${uuid.new_v4().str()}')
			os.mkdir_all(root) or { panic(err) }
			defer {
				os.rmdir_all(root) or {}
				os.rmdir_all(data) or {}
			}
			script := os.join_path(root, 'echo.mjs')
			os.write_file(script, "import readline from 'node:readline';\nconst lines = readline.createInterface({ input: process.stdin });\nfor await (const line of lines) {\n  const request = JSON.parse(line);\n  if (!request.id) continue;\n  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result: { ok: true, sandboxed: true } }) + '\\n');\n}\n") or {
				panic(err)
			}
			mut transport := start_plugin_mcp_transport(root, data, PluginMCPServer{
				name:      'sandbox-fixture'
				transport: 'stdio'
				command:   node
				args:      [script]
			}) or { panic(err) }
			defer {
				transport.close()
			}
			assert transport.mcp_stdio_alive()
			assert transport.process.filename == macos_seatbelt_executable
		} else {
			root := os.join_path(os.temp_dir(), 'veasel-mcp-sandbox-refuse-${uuid.new_v4().str()}')
			data := os.join_path(os.temp_dir(), 'veasel-mcp-sandbox-refuse-data-${uuid.new_v4().str()}')
			os.mkdir_all(root) or { panic(err) }
			defer {
				os.rmdir_all(root) or {}
				os.rmdir_all(data) or {}
			}
			start_plugin_mcp_transport(root, data, PluginMCPServer{
				name:      'refuse'
				transport: 'stdio'
				command:   '/usr/bin/false'
				args:      []string{}
			}) or {
				assert err.msg().contains('sandbox-exec')
				return
			}
			assert false, 'expected require mode to refuse macOS MCP stdio without sandbox-exec'
		}
	} $else $if windows {
		assert !mcp_stdio_sandbox_bubblewrap_capability()
		assert !mcp_stdio_sandbox_seatbelt_capability()
		assert mcp_stdio_sandbox_windows_capability() == windows_appcontainer_sandbox_available()
		if windows_appcontainer_sandbox_available() {
			node := os.find_abs_path_of_executable('node') or { return }
			root := os.join_path(os.temp_dir(), 'veasel-mcp-sandbox-${uuid.new_v4().str()}')
			data := os.join_path(os.temp_dir(), 'veasel-mcp-sandbox-data-${uuid.new_v4().str()}')
			os.mkdir_all(root) or { panic(err) }
			defer {
				os.rmdir_all(root) or {}
				os.rmdir_all(data) or {}
			}
			script := os.join_path(root, 'echo.mjs')
			os.write_file(script, "import readline from 'node:readline';\nconst lines = readline.createInterface({ input: process.stdin });\nfor await (const line of lines) {\n  const request = JSON.parse(line);\n  if (!request.id) continue;\n  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result: { ok: true, sandboxed: true } }) + '\\n');\n}\n") or {
				panic(err)
			}
			mut transport := start_plugin_mcp_transport(root, data, PluginMCPServer{
				name:      'sandbox-fixture'
				transport: 'stdio'
				command:   node
				args:      [script]
			}) or { panic(err) }
			defer {
				transport.close()
			}
			assert transport.mcp_stdio_alive()
			assert !isnil(transport.win_mcp)
		} else {
			root := os.join_path(os.temp_dir(), 'veasel-mcp-sandbox-refuse-${uuid.new_v4().str()}')
			data := os.join_path(os.temp_dir(), 'veasel-mcp-sandbox-refuse-data-${uuid.new_v4().str()}')
			os.mkdir_all(root) or { panic(err) }
			defer {
				os.rmdir_all(root) or {}
				os.rmdir_all(data) or {}
			}
			start_plugin_mcp_transport(root, data, PluginMCPServer{
				name:      'refuse'
				transport: 'stdio'
				command:   'C:\\Windows\\System32\\cmd.exe'
				args:      ['/c', 'exit', '1']
			}) or {
				assert err.msg().contains('AppContainer')
				return
			}
			assert false, 'expected require mode to refuse Windows MCP stdio without AppContainer'
		}
	} $else {
		assert !mcp_stdio_sandbox_bubblewrap_capability()
		assert !mcp_stdio_sandbox_seatbelt_capability()
		assert !mcp_stdio_sandbox_windows_capability()
		root := os.join_path(os.temp_dir(), 'veasel-mcp-sandbox-refuse-${uuid.new_v4().str()}')
		data := os.join_path(os.temp_dir(), 'veasel-mcp-sandbox-refuse-data-${uuid.new_v4().str()}')
		os.mkdir_all(root) or { panic(err) }
		defer {
			os.rmdir_all(root) or {}
			os.rmdir_all(data) or {}
		}
		start_plugin_mcp_transport(root, data, PluginMCPServer{
			name:      'refuse'
			transport: 'stdio'
			command:   '/bin/false'
			args:      []string{}
		}) or {
			assert err.msg().contains('require')
			return
		}
		assert false, 'expected require mode to refuse MCP stdio without a platform sandbox backend'
	}
}

fn test_mcp_stdio_sandbox_seatbelt_profile_carves_plugin_roots_and_allows_network() {
	profile := macos_mcp_seatbelt_profile()
	assert profile.contains('(param "PLUGIN_ROOT")')
	assert profile.contains('(param "PLUGIN_DATA")')
	assert profile.contains('(allow network-outbound)')
	assert profile.contains('(deny default)')
}

fn test_plugin_mcp_frame_buffer_handles_fragmented_and_buffered_frames() {
	mut buffer := PluginMCPFrameBuffer{}
	assert buffer.append('{"id":')! == ''
	assert buffer.append('1}\r\n{"id":2}\n')! == '{"id":1}'
	assert buffer.read_from > 0
	assert buffer.take_frame()! == '{"id":2}'
	assert buffer.read_from == 0
	assert buffer.take_frame()! == ''
}

fn test_plugin_mcp_frame_buffer_rejects_empty_frames() {
	mut empty := PluginMCPFrameBuffer{}
	_ = empty.append('\n') or {
		assert err.msg() == 'MCP server returned an empty frame'
		return
	}
	assert false
}

fn test_plugin_mcp_frame_buffer_enforces_frame_size_limit() {
	mut oversized := PluginMCPFrameBuffer{}
	_ = oversized.append(strings.repeat(`x`, max_plugin_mcp_frame_bytes + 1)) or {
		assert err.msg() == 'MCP response exceeds the frame size limit'
		return
	}
	assert false
}

fn test_mcp_stdio_refusal_names_what_to_install_and_the_opt_in() {
	for os_name in ['linux', 'macos', 'windows', 'other'] {
		msg := mcp_stdio_sandbox_refusal_for(os_name)
		assert msg.contains(shell_sandbox_install_hint(os_name))
		assert msg.contains(shell_sandbox_opt_in_env)
		assert msg.contains('No server process was started')
	}
}

fn test_mcp_stdio_preview_reports_unsandboxed_only_with_opt_in() {
	prior_mode := os.getenv_opt(mcp_stdio_sandbox_mode_env)
	prior_opt := os.getenv_opt(shell_sandbox_opt_in_env)
	defer {
		if v := prior_mode {
			os.setenv(mcp_stdio_sandbox_mode_env, v, true)
		} else {
			os.unsetenv(mcp_stdio_sandbox_mode_env)
		}
		if v := prior_opt {
			os.setenv(shell_sandbox_opt_in_env, v, true)
		} else {
			os.unsetenv(shell_sandbox_opt_in_env)
		}
	}
	os.setenv(mcp_stdio_sandbox_mode_env, 'off', true)
	os.unsetenv(shell_sandbox_opt_in_env)
	refused := mcp_stdio_review_sandbox_preview()
	assert !refused.will_wrap && !refused.unsandboxed
	assert refused.network == 'none'
	assert !mcp_stdio_unsandboxed_capability()
	os.setenv(shell_sandbox_opt_in_env, shell_unsandboxed_opt_in_token, true)
	opted := mcp_stdio_review_sandbox_preview()
	assert opted.unsandboxed && !opted.will_wrap
	assert opted.network == 'host'
	assert mcp_stdio_unsandboxed_capability()
}

fn test_plugin_mcp_missing_plugin_root_is_rejected() {
	// A real plugin package whose root does not exist must keep failing
	// canonicalization: only the synthetic configured-server root is
	// created by the caller, never an arbitrary missing package path.
	root := os.join_path(os.temp_dir(), 'veasel-mcp-missing-root-${os.getpid()}')
	data := os.join_path(os.temp_dir(), 'veasel-mcp-missing-data-${os.getpid()}')
	os.mkdir_all(data) or { panic(err) }
	defer {
		os.rmdir_all(data) or {}
	}
	server := PluginMCPServer{
		name:      'fixture'
		transport: 'stdio'
		command:   'true'
		cwd:       './'
	}
	if _ := start_plugin_mcp_fixture_transport(root, data, server) {
		assert false, 'missing plugin root must be rejected'
	}
	assert !os.exists(root)
}

fn test_plugin_mcp_configured_synthetic_root_starts_after_ensure() {
	node := os.find_abs_path_of_executable('node') or {
		if os.getenv('CI') == 'true' {
			panic('Node.js is required to run the MCP process fixture in CI')
		}
		return
	}
	// Mirrors the configured-server flow in load_session_plugin_mcp_tools:
	// the synthetic package root does not exist until the caller ensures
	// it, after which the transport must start and initialize normally.
	root := os.join_path(os.temp_dir(), 'veasel-mcp-configured-root-${os.getpid()}')
	data := os.join_path(os.temp_dir(), 'veasel-mcp-configured-data-${os.getpid()}')
	defer {
		os.rmdir_all(root) or {}
		os.rmdir_all(data) or {}
	}
	assert !os.exists(root)
	ensure_directory(root) or { panic(err) }
	script := os.join_path(root, 'fixture.mjs')
	fixture := "import readline from 'node:readline';\n" +
		'const lines = readline.createInterface({ input: process.stdin });\n' +
		'for await (const line of lines) {\n' +
		'  const request = JSON.parse(line);\n' +
		'  if (!request.id) continue;\n' +
		"  const result = request.method === 'initialize' ? { protocolVersion: '2025-11-25', capabilities: { tools: {} }, serverInfo: { name: 'fixture', version: '1.0.0' } } : {};\n" +
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
	mut client := new_plugin_mcp_fixture_client(root, data, server) or { panic(err) }
	defer {
		client.close()
	}
	client.initialize() or { panic(err) }
}

fn test_linux_mcp_sandbox_command_binds_cover_venv_and_interpreter() {
	base := os.join_path(os.temp_dir(), 'veasel-mcp-binds-${os.getpid()}')
	venv := os.join_path(base, 'venv')
	bin_dir := os.join_path(venv, 'bin')
	os.mkdir_all(bin_dir) or { panic(err) }
	defer {
		os.rmdir_all(base) or {}
	}
	os.write_file(os.join_path(venv, 'pyvenv.cfg'), 'home = /usr/bin\n') or { panic(err) }
	tool := os.join_path(bin_dir, 'fake-mcp')
	os.write_file(tool, '#!${os.join_path(bin_dir, 'python')}\nprint(1)\n') or { panic(err) }
	os.write_file(os.join_path(bin_dir, 'python'), 'fake interpreter placeholder\n') or { panic(err) }
	os.chmod(tool, 0o755) or {}
	binds := linux_mcp_sandbox_command_binds(tool, {
		'PATH': '/usr/bin:/bin'
	})
	assert binds == [os.real_path(venv)], 'expected the venv tree only, got ${binds}'
}

fn test_linux_mcp_sandbox_command_binds_skip_visible_and_broad_paths() {
	// A system executable outside the hidden roots needs no bind.
	visible := linux_mcp_sandbox_command_binds('/bin/true', {
		'PATH': '/usr/bin:/bin'
	})
	assert visible.len == 0
	// An executable sitting directly in a hidden root must never widen
	// the bind to that whole root.
	base := os.join_path(os.temp_dir(), 'veasel-mcp-broad-${os.getpid()}.sh')
	os.write_file(base, '#!/bin/sh\nexit 0\n') or { panic(err) }
	defer {
		os.rm(base) or {}
	}
	os.chmod(base, 0o755) or {}
	broad := linux_mcp_sandbox_command_binds(base, {
		'PATH': '/usr/bin:/bin'
	})
	assert os.temp_dir() !in broad
	for bind in broad {
		assert bind != '/tmp'
		assert bind != '/home'
	}
}

fn test_linux_mcp_sandbox_command_binds_follow_symlink_chains() {
	// uv-style layout: venv/bin/python -> uv/python/cpython-3 (directory
	// symlink alias) -> uv/python/cpython-3.14/bin/python3.14. Binding only
	// the endpoints still breaks exec: the intermediate alias directory
	// must stay visible for the kernel to resolve the chain.
	base := os.join_path(os.temp_dir(), 'veasel-mcp-chain-${os.getpid()}')
	venv := os.join_path(base, 'venv')
	venv_bin := os.join_path(venv, 'bin')
	py_root := os.join_path(base, 'uv-python', 'cpython-3.14')
	py_bin := os.join_path(py_root, 'bin')
	os.mkdir_all(venv_bin) or { panic(err) }
	os.mkdir_all(py_bin) or { panic(err) }
	os.mkdir_all(os.join_path(py_root, 'lib')) or { panic(err) }
	defer {
		os.rmdir_all(base) or {}
	}
	os.write_file(os.join_path(venv, 'pyvenv.cfg'), 'home = /usr/bin\n') or { panic(err) }
	os.write_file(os.join_path(py_bin, 'python3.14'), 'fake interpreter placeholder\n') or {
		panic(err)
	}
	alias := os.join_path(base, 'uv-python', 'cpython-3')
	os.symlink(py_root, alias) or { panic(err) }
	venv_python := os.join_path(venv_bin, 'python')
	os.symlink(os.join_path(alias, 'bin', 'python3.14'), venv_python) or { panic(err) }
	tool := os.join_path(venv_bin, 'fake-mcp')
	os.write_file(tool, '#!${venv_python}\nprint(1)\n') or { panic(err) }
	os.chmod(tool, 0o755) or {}

	binds := linux_mcp_sandbox_command_binds(tool, {
		'PATH': '/usr/bin:/bin'
	})
	assert os.real_path(venv) in binds, 'venv tree missing from ${binds}'
	assert os.real_path(py_root) in binds, 'interpreter tree missing from ${binds}'
	assert os.real_path(os.join_path(base, 'uv-python')) in binds, 'alias parent dir missing from ${binds}'
	for bind in binds {
		assert bind != os.temp_dir()
		assert bind.starts_with(os.real_path(base))
	}
}
