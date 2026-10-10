module main

import json2
import mcp
import net.http
import os
import time
import uuid

struct PluginMCPHTTPFixture {
mut:
	redirect_target_hits int
	supports_2026        bool = true
}

fn (mut fixture PluginMCPHTTPFixture) handle(request http.Request) http.Response {
	mut response := http.Response{}
	if request.url == '/redirect' {
		response.set_status(.found)
		response.header.set_custom('Location', '/redirect-target') or {}
		return response
	}
	if request.url == '/redirect-target' {
		fixture.redirect_target_hits++
		response.body = 'redirect must not be followed'
		return response
	}
	if request.url != '/mcp' || request.method != .post
		|| request.header.get_custom('X-Plugin-Token') or { '' } != 'fixture-token' {
		response.set_status(.forbidden)
		response.header.set(.content_type, 'text/plain')
		response.body = 'invalid request: url=${request.url}, method=${request.method}, token=${request.header.get_custom('X-Plugin-Token') or { '' }}'
		return response
	}
	request_message := json2.decode[map[string]json2.Any](request.data) or {
		response.set_status(.bad_request)
		return response
	}
	method_value := request_message['method'] or { json2.Any('') }
	if method_value !is string {
		response.set_status(.bad_request)
		return response
	}
	method := method_value as string
	if method == 'server/discover' {
		if !fixture.supports_2026 {
			id := request_message['id'] or {
				response.set_status(.bad_request)
				return response
			}
			response.set_status(.bad_request)
			response.header.set(.content_type, 'application/json')
			response.body = '{"jsonrpc":"2.0","id":${json2.encode[json2.Any](id)},"error":{"code":-32022,"message":"Unsupported protocol version","data":{"supported":["2025-11-25"],"requested":"2026-07-28"}}}'
			return response
		}
		if request.header.get_custom('MCP-Protocol-Version') or { '' } != '2026-07-28'
			|| request.header.get_custom('Mcp-Method') or { '' } != 'server/discover'
			|| request.header.get_custom('MCP-Session-Id') or { '' } != '' {
			response.set_status(.bad_request)
			response.header.set(.content_type, 'text/plain')
			response.body = 'invalid discovery headers: version=${request.header.get_custom('MCP-Protocol-Version') or { '' }}, method=${request.header.get_custom('Mcp-Method') or { '' }}, session=${request.header.get_custom('MCP-Session-Id') or { '' }}'
			return response
		}
		id := request_message['id'] or {
			response.set_status(.bad_request)
			return response
		}
		response.header.set(.content_type, 'application/json')
		response.body = '{"jsonrpc":"2.0","id":${json2.encode[json2.Any](id)},"result":{"supportedVersions":["2026-07-28"],"capabilities":{"tools":{}}}}'
		return response
	}
	if method == 'notifications/initialized' {
		if request.header.get_custom('MCP-Session-Id') or { '' } != 'fixture-session'
			|| request.header.get_custom('MCP-Protocol-Version') or { '' } != '2025-11-25' {
			response.set_status(.bad_request)
			return response
		}
		response.set_status(.accepted)
		return response
	}
	id := request_message['id'] or {
		response.set_status(.bad_request)
		return response
	}
	id_json := json2.encode[json2.Any](id)
	response.header.set(.content_type, 'application/json')
	if method == 'initialize' {
		response.header.set_custom('MCP-Session-Id', 'fixture-session') or {}
		response.header.set_custom('MCP-Protocol-Version', '2025-11-25') or {}
		response.body = '{"jsonrpc":"2.0","id":${id_json},"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1.0.0"}}}'
		return response
	}
	expected_version := if fixture.supports_2026 { '2026-07-28' } else { '2025-11-25' }
	expected_session := if fixture.supports_2026 { '' } else { 'fixture-session' }
	match method {
		'tools/list' {
			if request.header.get_custom('MCP-Session-Id') or { '' } != expected_session
				|| request.header.get_custom('MCP-Protocol-Version') or { '' } != expected_version
				|| (fixture.supports_2026
					&& request.header.get_custom('Mcp-Method') or { '' } != 'tools/list') {
				response.set_status(.bad_request)
				return response
			}
			response.header.set(.content_type, 'text/event-stream')
			response.body = 'event: message\ndata: {"jsonrpc":"2.0","id":${id_json},"result":{"tools":[{"name":"remote_fixture","description":"Remote fixture tool.","inputSchema":{"type":"object","properties":{},"additionalProperties":false}}]}}\n\n'
		}
		'tools/call' {
			if request.header.get_custom('MCP-Session-Id') or { '' } != expected_session
				|| request.header.get_custom('MCP-Protocol-Version') or { '' } != expected_version
				|| (fixture.supports_2026
					&& (request.header.get_custom('Mcp-Method') or { '' } != 'tools/call'
						|| request.header.get_custom('Mcp-Name') or { '' } != 'remote_fixture')) {
				response.set_status(.bad_request)
				return response
			}
			response.body = '{"jsonrpc":"2.0","id":${id_json},"result":{"content":[{"type":"text","text":"Remote MCP fixture result"}],"isError":false}}'
		}
		else {
			response.body = '{"jsonrpc":"2.0","id":${id_json},"result":{}}'
		}
	}
	return response
}

fn test_plugin_mcp_streamable_http_stateless_discovery_sse_tool_call_and_redirect_policy() {
	mut fixture := &PluginMCPHTTPFixture{}
	mut server := &http.Server{
		accept_timeout:       100 * time.millisecond
		handler:              fixture
		addr:                 '127.0.0.1:0'
		show_startup_message: false
	}
	server_thread := spawn server.listen_and_serve()
	server.wait_till_running() or {
		server.stop()
		server_thread.wait()
		panic(err)
	}
	defer {
		server.stop()
		server_thread.wait()
	}
	server_config := PluginMCPServer{
		name:      'remote'
		transport: 'streamable-http'
		url:       'http://${server.addr}/mcp'
		headers:   {
			'X-Plugin-Token': 'fixture-token'
		}
	}
	mut client := new_plugin_mcp_http_client(server_config) or { panic(err) }
	defer { client.close() }
	initialized := client.initialize() or { panic(err) }
	assert initialized.protocol_version == '2026-07-28'
	listed := client.request_message('tools/list', mcp.empty_object) or { panic(err) }
	assert listed.error.code == 0
	assert listed.result.contains('remote_fixture')
	arguments := json2.decode[json2.Any]('{}') or { panic(err) }
	called := client.request_message('tools/call', {
		'name':      json2.Any('remote_fixture')
		'arguments': arguments
	}) or { panic(err) }
	assert called.error.code == 0
	assert called.result.contains('Remote MCP fixture result')
	client.close()

	redirect_server_config := PluginMCPServer{
		name:      'redirect'
		transport: 'streamable-http'
		url:       'http://${server.addr}/redirect'
		headers:   {
			'X-Plugin-Token': 'fixture-token'
		}
	}
	mut redirect_transport := new_plugin_mcp_http_transport(redirect_server_config) or {
		panic(err)
	}
	redirect_error := plugin_mcp_http_transport_send_error(mut redirect_transport,
		'{"jsonrpc":"2.0","id":"1","method":"initialize","params":{}}')
	assert redirect_error.contains('redirects are disabled')
	assert fixture.redirect_target_hits == 0

	temp_root := os.join_path(os.temp_dir(), 'veasel-mcp-http-runtime-${uuid.new_v4().str()}')
	plugin_directory := os.join_path(temp_root, 'plugins')
	package_directory := os.join_path(plugin_directory, 'remote-package')
	workspace_directory := os.join_path(temp_root, 'workspace')
	os.mkdir_all(package_directory) or { panic(err) }
	os.mkdir_all(workspace_directory) or { panic(err) }
	defer { os.rmdir_all(temp_root) or {} }
	os.write_file(os.join_path(package_directory, 'plugin.json'), '{"$schema":"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json","name":"remote-plugin"}') or {
		panic(err)
	}
	os.write_file(os.join_path(package_directory, 'mcp.json'), '{"$schema":"https://agent-plugins.org/schemas/1.0.0/mcp.schema.json","mcpServers":{"remote":{"type":"streamable-http","url":"http://${server.addr}/mcp","headers":{"X-Plugin-Token":"fixture-token"}}}}') or {
		panic(err)
	}
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{
		title:     'Remote MCP fixture'
		directory: workspace_directory
	}) or { panic(err) }
	store.set_session_plugin_mcp_server(session.id, 'remote-plugin', 'remote', true) or { panic(err) }
	mut app := new_app(store, plugin_directory)
	defer { app.close() }
	tools, bindings, mut connections := app.load_session_plugin_mcp_tools(session.id) or { panic(err) }
	defer { close_plugin_mcp_connections(mut connections) }
	assert tools.len == 1
	response := execute_plugin_mcp_tool(mut connections, bindings[tools[0].name], '{}')
	assert response.contains('Remote MCP fixture result')

	fixture.supports_2026 = false
	mut fallback_client := new_plugin_mcp_http_client(server_config) or { panic(err) }
	defer { fallback_client.close() }
	fallback := fallback_client.initialize() or { panic(err) }
	assert fallback.protocol_version == '2025-11-25'
	fallback_tools := fallback_client.request_message('tools/list', mcp.empty_object) or {
		panic(err)
	}
	assert fallback_tools.error.code == 0
}

fn plugin_mcp_http_transport_send_error(mut transport PluginMCPHTTPTransport, message string) string {
	transport.send(message) or { return err.msg() }
	return ''
}

fn test_plugin_mcp_http_sse_parser_is_bounded_and_skips_non_message_events() {
	parsed := parse_plugin_mcp_http_sse(': heartbeat\nevent: endpoint\ndata: /events\n\nevent: message\ndata: {"jsonrpc":"2.0",\ndata: "id":"1"}\n\n') or {
		panic(err)
	}
	assert parsed == ['{"jsonrpc":"2.0",\n"id":"1"}']
	assert parse_plugin_mcp_http_sse('event: endpoint\ndata: /events\n\n') or { []string{} } == []string{}
	assert plugin_mcp_http_protocol_version('{"result":{"protocolVersion":"2025-11-25"}}') == '2025-11-25'
	assert plugin_mcp_http_protocol_version('{"result":{"protocolVersion":"bad\nheader"}}') == ''
	filtered := plugin_mcp_http_user_headers({
		'Authorization':       'Bearer fixture'
		'Host':                'attacker.example'
		'MCP-Session-Id':      'attacker-session'
		'X-Plugin-Configured': 'visible'
	})
	assert filtered == {
		'Authorization':       'Bearer fixture'
		'X-Plugin-Configured': 'visible'
	}
}
