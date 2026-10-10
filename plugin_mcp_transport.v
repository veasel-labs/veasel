module main

import mcp
import json2
import os
import strconv
import strings
import time

const max_plugin_mcp_frame_bytes = 1_000_000
const plugin_mcp_response_timeout = 20 * time.second
const max_session_plugin_mcp_servers = 8
const max_plugin_mcp_concurrency = 4
const max_session_plugin_mcp_tools = 64
const max_session_plugin_mcp_tool_pages = 16
const max_session_plugin_mcp_cursor_bytes = 1024

struct PluginMCPToolBinding {
	connection_index int
	native_name      string
}

struct PluginMCPConnection {
mut:
	client mcp.Client
}

// PluginMCPTransport supplies the process configuration missing from the
// stdlib convenience constructor while keeping MCP JSON-RPC in vlib/mcp.
struct PluginMCPTransport {
mut:
	process &os.Process
	buffer  string
}

fn start_plugin_mcp_transport(plugin_root string, plugin_data string, server PluginMCPServer) !PluginMCPTransport {
	if server.transport != 'stdio' || server.command.len == 0 {
		return error('unsupported Agent Plugin MCP server')
	}
	root := canonical_plugin_root(plugin_root)!
	data_parent := os.dir(os.real_path(plugin_data))
	os.mkdir_all(data_parent)!
	os.mkdir_all(plugin_data)!
	data := canonical_plugin_root(plugin_data)!
	$if !windows {
		os.chmod(data, 0o700)!
	}
	cwd := resolve_plugin_cwd(root, data, server.cwd)!
	mut env := plugin_mcp_base_environment()
	for key, value in server.env {
		env[key] = expand_plugin_placeholders(value, root, data)
	}
	env['PLUGIN_ROOT'] = root
	env['PLUGIN_DATA'] = data
	mut process := os.new_process(server.command)
	process.set_args(server.args.map(expand_plugin_placeholders(it, root, data)))
	process.set_work_folder(cwd)
	process.set_environment(env)
	process.set_redirect_stdio()
	process.run()
	if process.status != .running {
		process.close()
		return error('unable to start trusted Agent Plugin MCP server')
	}
	return PluginMCPTransport{
		process: process
	}
}

fn plugin_mcp_base_environment() map[string]string {
	mut env := map[string]string{}
	for key in ['PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'TMP', 'TEMP', 'LANG', 'LC_ALL',
		'SYSTEMROOT', 'WINDIR', 'PATHEXT', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'COMSPEC'] {
		if value := os.getenv_opt(key) {
			env[key] = value
		}
	}
	return env
}

fn (mut transport PluginMCPTransport) send(message string) ! {
	if message.len == 0 || message.len > max_plugin_mcp_frame_bytes {
		return error('MCP request exceeds the frame size limit')
	}
	if message.contains('\n') || message.contains('\r') {
		return error('MCP request contains invalid stdio framing')
	}
	transport.process.stdin_write(message + '\n')
}

fn (mut transport PluginMCPTransport) receive() !string {
	started := time.now()
	for {
		if time.since(started) > plugin_mcp_response_timeout {
			return error('MCP server response timed out')
		}
		if transport.process.is_pending(.stderr) {
			_ := transport.process.stderr_read()
		}
		if transport.process.is_pending(.stdout) {
			transport.buffer += transport.process.stdout_read()
			if transport.buffer.len > max_plugin_mcp_frame_bytes {
				return error('MCP response exceeds the frame size limit')
			}
			if newline := transport.buffer.index('\n') {
				frame := transport.buffer[..newline].trim_right('\r')
				transport.buffer = transport.buffer[newline + 1..]
				if frame.len == 0 {
					return error('MCP server returned an empty frame')
				}
				return frame
			}
		}
		if !transport.process.is_alive() {
			return error('MCP server exited before responding')
		}
		time.sleep(5 * time.millisecond)
	}
}

fn (mut transport PluginMCPTransport) close() {
	if transport.process.is_alive() {
		transport.process.signal_term()
		for _ in 0 .. 20 {
			if !transport.process.is_alive() {
				break
			}
			time.sleep(10 * time.millisecond)
		}
		if transport.process.is_alive() {
			transport.process.signal_kill()
		} else if transport.process.status in [.running, .stopped] {
			transport.process.wait()
		}
	}
	transport.process.close()
}

fn new_plugin_mcp_client(plugin_root string, plugin_data string, server PluginMCPServer) !(mcp.Client, PluginMCPTransport) {
	transport := start_plugin_mcp_transport(plugin_root, plugin_data, server)!
	return mcp.new_client(transport, mcp.ClientConfig{}), transport
}

fn (app &App) load_session_plugin_mcp_tools(session_id string) !([]AgentToolDefinition, map[string]PluginMCPToolBinding, []PluginMCPConnection) {
	mut active := app.store.session_plugin_mcp_servers(session_id)!
	if active.len > max_session_plugin_mcp_servers {
		// Older databases may contain more entries than the current trust limit.
		// Keep chat usable and apply the deterministic store ordering.
		eprintln('veasel: only the first ${max_session_plugin_mcp_servers} trusted MCP servers will be loaded')
		active = active[..max_session_plugin_mcp_servers]
	}
	mut definitions := []AgentToolDefinition{}
	mut bindings := map[string]PluginMCPToolBinding{}
	mut connections := []PluginMCPConnection{}
	for selected in active {
		plugin_root, server := find_agent_mcp_server(app.plugin_directory, selected.plugin_name,
			selected.server_name) or {
			eprintln('veasel: trusted MCP server configuration is no longer available')
			continue
		}
		plugin_data := os.join_path(app.plugin_data_directory, selected.plugin_name)
		mut client, _ := new_plugin_mcp_client(plugin_root, plugin_data, server) or {
			eprintln('veasel: trusted MCP server could not be started')
			continue
		}
		client.initialize() or {
			eprintln('veasel: trusted MCP server initialization failed')
			client.close()
			continue
		}
		connection_index := connections.len
		mut connection_has_tools := false
		mut cursor := ''
		mut seen_cursors := map[string]bool{}
		for page in 0 .. max_session_plugin_mcp_tool_pages {
			result := request_plugin_mcp_tool_page(mut client, cursor) or {
				eprintln('veasel: trusted MCP server tool listing failed')
				break
			}
			tool_values := result['tools'] or { break }
			if tool_values !is []json2.Any {
				break
			}
			for value in tool_values as []json2.Any {
				if definitions.len >= max_session_plugin_mcp_tools {
					client.close()
					close_plugin_mcp_connections(mut connections)
					return error('session exceeds the trusted MCP tool limit')
				}
				if value !is map[string]json2.Any {
					continue
				}
				fields := value as map[string]json2.Any
				native_name_value := fields['name'] or { continue }
				if native_name_value !is string {
					continue
				}
				native_name := native_name_value as string
				if native_name.len == 0 || native_name.len > 256 || native_name.contains('\0') {
					continue
				}
				schema_value := fields['inputSchema'] or { continue }
				schema := json2.encode[json2.Any](schema_value)
				if schema.len == 0 || schema.len > 64_000 {
					continue
				}
				parsed_schema := json2.decode[map[string]json2.Any](schema) or { continue }
				schema_type := parsed_schema['type'] or { continue }
				if schema_type !is string || schema_type as string != 'object' {
					continue
				}
				mut description := ''
				if desc := fields['description'] {
					if desc is string && desc.len <= 4_000 {
						description = desc as string
					}
				}
				provider_name := plugin_mcp_provider_name(selected.plugin_name,
					selected.server_name, native_name)
				if provider_name in bindings {
					continue
				}
				definitions << AgentToolDefinition{
					name:           provider_name
					description:    if description.len > 0 {
						'Untrusted plugin metadata: ' + description
					} else {
						'Untrusted MCP tool metadata.'
					}
					raw_parameters: schema
				}
				bindings[provider_name] = PluginMCPToolBinding{
					connection_index: connection_index
					native_name:      native_name
				}
				connection_has_tools = true
			}
			next_cursor_value := result['nextCursor'] or { break }
			if next_cursor_value !is string {
				eprintln('veasel: trusted MCP server returned an invalid tool cursor')
				break
			}
			next_cursor := next_cursor_value as string
			if next_cursor.len == 0 || next_cursor.len > max_session_plugin_mcp_cursor_bytes
				|| next_cursor.contains('\0') || seen_cursors[next_cursor] {
				eprintln('veasel: trusted MCP server returned an invalid tool cursor')
				break
			}
			if page == max_session_plugin_mcp_tool_pages - 1 {
				eprintln('veasel: trusted MCP server tool page limit reached')
				break
			}
			seen_cursors[next_cursor] = true
			cursor = next_cursor
		}
		if connection_has_tools {
			connections << PluginMCPConnection{
				client: client
			}
		} else {
			client.close()
		}
	}
	return definitions, bindings, connections
}

fn request_plugin_mcp_tool_page(mut client mcp.Client, cursor string) !map[string]json2.Any {
	mut params := map[string]json2.Any{}
	if cursor.len > 0 {
		params['cursor'] = json2.Any(cursor)
	}
	response := client.request_message('tools/list', params)!
	if response.error.code != 0 || response.result.len > max_plugin_mcp_frame_bytes {
		return error('invalid or oversized MCP tool page')
	}
	return json2.decode[map[string]json2.Any](response.result) or {
		return error('MCP server returned invalid tool page JSON')
	}
}

fn close_plugin_mcp_connections(mut connections []PluginMCPConnection) {
	for index in 0 .. connections.len {
		connections[index].client.close()
	}
}

fn plugin_mcp_provider_name(plugin_name string, server_name string, native_name string) string {
	raw := 'mcp_${plugin_name}_${server_name}_${native_name}'
	mut builder := strings.new_builder(64)
	mut count := 0
	for c in raw {
		if count >= 48 {
			break
		}
		if c.is_alnum() || c == `_` || c == `-` {
			builder.write_u8(c)
		} else {
			builder.write_u8(`_`)
		}
		count++
	}
	hash := strconv.format_int(i64(raw.hash()), 16)
	return '${builder.str()}_${hash}'
}

fn execute_plugin_mcp_tool(mut connections []PluginMCPConnection, binding PluginMCPToolBinding,
	arguments string) string {
	if binding.connection_index < 0 || binding.connection_index >= connections.len {
		return '{"error":"MCP server connection is unavailable."}'
	}
	parsed_arguments := json2.decode[json2.Any](arguments) or {
		return '{"error":"MCP tool arguments are invalid."}'
	}
	if parsed_arguments !is map[string]json2.Any {
		return '{"error":"MCP tool arguments must be an object."}'
	}
	params := {
		'name':      json2.Any(binding.native_name)
		'arguments': parsed_arguments
	}
	response := connections[binding.connection_index].client.request_message('tools/call', params) or {
		return '{"error":"MCP tool call failed."}'
	}
	if response.error.code != 0 || response.result.len > max_agent_tool_result_bytes {
		return '{"error":"MCP tool returned an error or oversized result."}'
	}
	return response.result
}
