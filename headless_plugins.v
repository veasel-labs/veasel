module main

import json2
import net.http
import os

// Headless Agent Plugin component enable/disable. Calls /v1/plugins/components.
// Does not install packages, trust MCP servers, or execute skill scripts.

enum HeadlessPluginsAction {
	components_list
	components_enable
	components_disable
}

struct HeadlessPluginsOptions {
mut:
	action HeadlessPluginsAction
	plugin string
	kind   string
	name   string
	json   bool
}

fn print_headless_plugins_help() {
	println('Usage: veasel plugins components <list|enable|disable> [options]\n\nCommands:\n  components list [--json]\n  components enable <plugin> <skill|mcp> <name>\n  components disable <plugin> <skill|mcp> <name>\n\nOptions:\n      --json  Emit machine-readable JSON\n  -h, --help  Show this help\n\nPersists overrides in \$VEASEL_DATA_DIR/plugin-components.json via PATCH /v1/plugins/components.\nAbsent entries default to enabled. Disabled skills cannot be session-activated; disabled MCP servers cannot be trusted.')
}

fn parse_headless_plugins_args(args []string) !HeadlessPluginsOptions {
	mut options := HeadlessPluginsOptions{}
	if args.len == 0 {
		return error('help')
	}
	mut index := 0
	group := args[index]
	index++
	if group in ['--help', '-h', 'help'] {
		return error('help')
	}
	if group != 'components' {
		return error('unknown plugins command: ${group}')
	}
	if index >= args.len {
		return error('plugins components expects list|enable|disable')
	}
	action := args[index]
	index++
	match action {
		'list' {
			options.action = .components_list
		}
		'enable' {
			options.action = .components_enable
		}
		'disable' {
			options.action = .components_disable
		}
		'--help', '-h', 'help' {
			return error('help')
		}
		else {
			return error('unknown plugins components command: ${action}')
		}
	}
	mut positional := []string{}
	for index < args.len {
		arg := args[index]
		match arg {
			'--json' {
				options.json = true
			}
			'--help', '-h' {
				return error('help')
			}
			else {
				if arg.starts_with('-') {
					return error('unknown plugins option: ${arg}')
				}
				positional << arg
			}
		}
		index++
	}
	match options.action {
		.components_list {
			if positional.len > 0 {
				return error('plugins components list does not take positional arguments')
			}
		}
		.components_enable, .components_disable {
			if positional.len != 3 {
				return error('plugins components enable|disable expects <plugin> <skill|mcp> <name>')
			}
			options.plugin = positional[0]
			options.kind = positional[1]
			options.name = positional[2]
			if options.kind !in [plugin_component_kind_skill, plugin_component_kind_mcp] {
				return error('component kind must be skill or mcp')
			}
		}
	}
	return options
}

fn headless_plugins_api_error(response http.Response) string {
	decoded := json2.decode[APIError](response.body) or { return 'HTTP ${response.status_code}' }
	if decoded.error.len > 0 {
		return decoded.error
	}
	return 'HTTP ${response.status_code}'
}

fn execute_headless_plugins_components_list(port int, options HeadlessPluginsOptions) !string {
	response := headless_json_request(port, .get, '/v1/plugins/components', '', false, '')!
	if response.status_code != 200 {
		return error(headless_plugins_api_error(response))
	}
	if options.json {
		return response.body
	}
	catalog := json2.decode[PluginComponentCatalog](response.body)!
	mut lines := []string{cap: catalog.components.len + 2}
	lines << 'Plugin component overrides (${catalog.components.len})'
	if catalog.path.len > 0 {
		lines << 'path  ${catalog.path}'
	}
	if catalog.components.len == 0 {
		lines << '(none — all discovered components default to enabled)'
	}
	for component in catalog.components {
		state := if component.enabled { 'enabled' } else { 'disabled' }
		lines << '${component.plugin}/${component.kind}/${component.name}  ${state}'
	}
	return lines.join('\n')
}

fn execute_headless_plugins_components_toggle(port int, options HeadlessPluginsOptions, enabled bool) !string {
	payload := PluginComponentToggleInput{
		plugin:  options.plugin
		kind:    options.kind
		name:    options.name
		enabled: enabled
	}
	response := headless_json_request(port, .patch, '/v1/plugins/components', json2.encode(payload),
		false, '')!
	if response.status_code != 200 {
		return error(headless_plugins_api_error(response))
	}
	if options.json {
		return response.body
	}
	view := json2.decode[PluginComponentView](response.body)!
	state := if view.enabled { 'enabled' } else { 'disabled' }
	return '${view.plugin}/${view.kind}/${view.name}  ${state}'
}

fn execute_headless_plugins_command(port int, args []string) {
	options := parse_headless_plugins_args(args) or {
		if err.msg() == 'help' {
			print_headless_plugins_help()
			return
		}
		eprintln('veasel: ${err.msg()}')
		print_headless_plugins_help()
		exit(2)
	}
	ensure_backend(port, '') or {
		eprintln('veasel: ${err.msg()}')
		exit(1)
	}
	output := match options.action {
		.components_list {
			execute_headless_plugins_components_list(port, options) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
		.components_enable {
			execute_headless_plugins_components_toggle(port, options, true) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
		.components_disable {
			execute_headless_plugins_components_toggle(port, options, false) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
	}
	println(output)
}
