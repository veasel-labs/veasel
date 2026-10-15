module main

import json2
import net.http
import net.urllib
import os

// Headless configured-MCP management. Calls the same /v1/mcp-servers API as the
// TUI. Does not trust servers, approve tool calls, or run install scripts.

enum HeadlessMcpAction {
	list
	add
	enable
	disable
	remove
}

struct HeadlessMcpOptions {
mut:
	action    HeadlessMcpAction
	scope     string = configured_mcp_scope_user
	directory string
	name      string
	transport string
	command   string
	args      []string
	url       string
	json      bool
}

fn print_headless_mcp_help() {
	println('Usage: veasel mcp <list|add|enable|disable|remove> [options]\n\nCommands:\n  list [--directory <dir>] [--json]\n  add [user|project] stdio <name> <command> [args…]\n  add [user|project] http <name> <url>\n  enable|disable|remove [user|project] <name>\n\nOptions:\n  -w, --directory <dir>  Workspace for project scope and list imports (default: cwd)\n      --json             Emit machine-readable JSON\n  -h, --help             Show this help\n\nPersistence:\n  user     \$VEASEL_DATA_DIR/mcp-servers.json\n  project  <directory>/.veasel/mcp-servers.json\n\nList also reports read-only imports of portable .mcp.json and .cursor/mcp.json.\nTrust remains separate (TUI /mcp trust configured/<name>). No install scripts run.\nStdio processes use your OS privileges; MCP results go to the model provider.')
}

fn parse_headless_mcp_args(args []string, cwd string) !HeadlessMcpOptions {
	mut options := HeadlessMcpOptions{
		directory: cwd
	}
	if args.len == 0 {
		return error('help')
	}
	mut index := 0
	action := args[index]
	index++
	match action {
		'list' {
			options.action = .list
		}
		'add' {
			options.action = .add
		}
		'enable' {
			options.action = .enable
		}
		'disable' {
			options.action = .disable
		}
		'remove' {
			options.action = .remove
		}
		'--help', '-h', 'help' {
			return error('help')
		}
		else {
			return error('unknown mcp command: ${action}')
		}
	}
	mut positional := []string{}
	mut options_done := false
	for index < args.len {
		arg := args[index]
		if !options_done {
			match arg {
				'--' {
					options_done = true
					index++
					continue
				}
				'--directory', '-w' {
					index++
					if index >= args.len || args[index].trim_space().len == 0 {
						return error('--directory expects a workspace path')
					}
					options.directory = args[index]
					index++
					continue
				}
				'--json' {
					options.json = true
					index++
					continue
				}
				'--help', '-h' {
					return error('help')
				}
				else {}
			}
		}
		// Stdio args may start with '-' (for example --noop); treat unknown
		// tokens as positionals once option scanning has consumed known flags.
		positional << arg
		index++
	}
	match options.action {
		.list {
			if positional.len > 0 {
				return error('mcp list does not take positional arguments')
			}
		}
		.add {
			parse_headless_mcp_add(mut options, positional)!
		}
		.enable, .disable, .remove {
			parse_headless_mcp_named(mut options, positional)!
		}
	}
	if options.scope == configured_mcp_scope_project && options.directory.trim_space().len == 0 {
		return error('project-scoped MCP requires --directory')
	}
	return options
}

fn parse_headless_mcp_add(mut options HeadlessMcpOptions, positional []string) ! {
	mut rest := positional.clone()
	if rest.len > 0 && rest[0] in [configured_mcp_scope_user, configured_mcp_scope_project] {
		options.scope = rest[0]
		rest = rest[1..]
	}
	if rest.len < 2 {
		return error('mcp add expects stdio <name> <command> [args…] or http <name> <url>')
	}
	kind := rest[0]
	options.name = rest[1]
	match kind {
		'stdio' {
			if rest.len < 3 {
				return error('mcp add stdio expects <name> <command> [args…]')
			}
			options.transport = 'stdio'
			options.command = rest[2]
			options.args = rest[3..]
		}
		'http' {
			if rest.len != 3 {
				return error('mcp add http expects <name> <url>')
			}
			options.transport = 'streamable-http'
			options.url = rest[2]
		}
		else {
			return error('mcp add transport must be stdio or http')
		}
	}
}

fn parse_headless_mcp_named(mut options HeadlessMcpOptions, positional []string) ! {
	mut rest := positional.clone()
	if rest.len > 0 && rest[0] in [configured_mcp_scope_user, configured_mcp_scope_project] {
		options.scope = rest[0]
		rest = rest[1..]
	}
	if rest.len != 1 {
		action := match options.action {
			.enable { 'enable' }
			.disable { 'disable' }
			.remove { 'remove' }
			else { 'manage' }
		}
		return error('mcp ${action} expects [user|project] <name>')
	}
	options.name = rest[0]
}

fn headless_mcp_directory_query(directory string) string {
	trimmed := directory.trim_space()
	if trimmed.len == 0 {
		return ''
	}
	return 'directory=${urllib.query_escape(trimmed)}'
}

fn headless_mcp_scope_query(scope string, directory string) string {
	mut parts := ['scope=${urllib.query_escape(scope)}']
	dir_query := headless_mcp_directory_query(directory)
	if dir_query.len > 0 && scope == configured_mcp_scope_project {
		parts << dir_query
	}
	return parts.join('&')
}

fn headless_mcp_api_error(response http.Response) string {
	decoded := json2.decode[APIError](response.body) or {
		return 'HTTP ${response.status_code}'
	}
	if decoded.error.len > 0 {
		return decoded.error
	}
	return 'HTTP ${response.status_code}'
}

fn execute_headless_mcp_list(port int, options HeadlessMcpOptions) !string {
	query := headless_mcp_directory_query(options.directory)
	path := if query.len > 0 { '/v1/mcp-servers?${query}' } else { '/v1/mcp-servers' }
	response := headless_json_request(port, .get, path, '', false, '')!
	if response.status_code != 200 {
		return error(headless_mcp_api_error(response))
	}
	if options.json {
		return response.body
	}
	catalog := json2.decode[ConfiguredMCPCatalog](response.body)!
	mut lines := []string{cap: catalog.servers.len + 4}
	lines << 'Configured MCP (${catalog.scope})'
	if catalog.path.len > 0 {
		lines << 'user file: ${catalog.path}'
	}
	if catalog.project_path.len > 0 {
		lines << 'project file: ${catalog.project_path}'
	}
	for import_path in catalog.import_paths {
		lines << 'import: ${import_path}'
	}
	if catalog.servers.len == 0 {
		lines << '(none)'
	}
	for server in catalog.servers {
		state := if server.enabled { 'enabled' } else { 'disabled' }
		detail := if server.transport == 'stdio' {
			server.command
		} else {
			server.url_origin
		}
		source := if server.config_file.len > 0 { ' · ${server.config_file}' } else { '' }
		lines << '${state}  configured/${server.name} [${server.transport}] · ${server.scope}${source}  ${detail}'
	}
	return lines.join('\n')
}

fn execute_headless_mcp_add(port int, options HeadlessMcpOptions) !string {
	mut payload := map[string]json2.Any{}
	payload['name'] = options.name
	payload['transport'] = options.transport
	payload['enabled'] = true
	payload['scope'] = options.scope
	if options.scope == configured_mcp_scope_project {
		payload['directory'] = options.directory
	}
	if options.transport == 'stdio' {
		payload['command'] = options.command
		mut args := []json2.Any{cap: options.args.len}
		for argument in options.args {
			args << argument
		}
		payload['args'] = args
	} else {
		payload['url'] = options.url
	}
	response := headless_json_request(port, .post, '/v1/mcp-servers', json2.encode(payload),
		false, '')!
	if response.status_code != 200 {
		return error(headless_mcp_api_error(response))
	}
	if options.json {
		return response.body
	}
	view := json2.decode[ConfiguredMCPServerView](response.body)!
	return 'Added configured/${view.name} [${view.transport}] (${view.scope}). Trust with the TUI: /mcp trust configured/${view.name}'
}

fn execute_headless_mcp_toggle(port int, options HeadlessMcpOptions, enabled bool) !string {
	query := headless_mcp_scope_query(options.scope, options.directory)
	path := '/v1/mcp-servers/${urllib.path_escape(options.name)}?${query}'
	response := headless_json_request(port, .patch, path, json2.encode({
		'enabled': json2.Any(enabled)
	}), false, '')!
	if response.status_code != 200 {
		return error(headless_mcp_api_error(response))
	}
	if options.json {
		return response.body
	}
	view := json2.decode[ConfiguredMCPServerView](response.body)!
	verb := if enabled { 'Enabled' } else { 'Disabled' }
	return '${verb} configured/${view.name} (${view.scope})'
}

fn execute_headless_mcp_remove(port int, options HeadlessMcpOptions) !string {
	query := headless_mcp_scope_query(options.scope, options.directory)
	path := '/v1/mcp-servers/${urllib.path_escape(options.name)}?${query}'
	response := headless_json_request(port, .delete, path, '', false, '')!
	if response.status_code != 200 {
		return error(headless_mcp_api_error(response))
	}
	if options.json {
		return response.body
	}
	removal := json2.decode[ConfiguredMCPRemoval](response.body)!
	return 'Removed configured/${removal.removed} (${options.scope})'
}

fn execute_headless_mcp_command(port int, args []string) {
	options := parse_headless_mcp_args(args, os.getwd()) or {
		if err.msg() == 'help' {
			print_headless_mcp_help()
			return
		}
		eprintln('veasel: ${err.msg()}')
		print_headless_mcp_help()
		exit(2)
	}
	ensure_backend(port, '') or {
		eprintln('veasel: ${err.msg()}')
		exit(1)
	}
	output := match options.action {
		.list {
			execute_headless_mcp_list(port, options) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
		.add {
			execute_headless_mcp_add(port, options) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
		.enable {
			execute_headless_mcp_toggle(port, options, true) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
		.disable {
			execute_headless_mcp_toggle(port, options, false) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
		.remove {
			execute_headless_mcp_remove(port, options) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
	}
	println(output)
}
