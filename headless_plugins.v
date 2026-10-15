module main

import json2
import net.http
import net.urllib
import os

// Headless Agent Plugin management. Calls /v1/plugins/components and
// /v1/plugins/links. Does not trust MCP servers or execute skill scripts.

enum HeadlessPluginsAction {
	components_list
	components_enable
	components_disable
	links_list
	links_add
	links_remove
}

struct HeadlessPluginsOptions {
mut:
	action HeadlessPluginsAction
	plugin string
	kind   string
	name   string
	path   string
	json   bool
}

fn print_headless_plugins_help() {
	println('Usage: veasel plugins <components|links> …\n\nCommands:\n  components list [--json]\n  components enable <plugin> <skill|mcp> <name>\n  components disable <plugin> <skill|mcp> <name>\n  links list [--json]\n  links add <absolute-package-path>\n  links remove <name>\n\nOptions:\n      --json  Emit machine-readable JSON\n  -h, --help  Show this help\n\nComponents persist in \$VEASEL_DATA_DIR/plugin-components.json.\nLinks create symlinks under \$VEASEL_PLUGIN_DIR; PLUGIN_DATA stays keyed by plugin name.')
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
	if group !in ['components', 'links'] {
		return error('unknown plugins command: ${group}')
	}
	if index >= args.len {
		return error('plugins ${group} expects a subcommand')
	}
	action := args[index]
	index++
	match group {
		'components' {
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
		}
		'links' {
			match action {
				'list' {
					options.action = .links_list
				}
				'add' {
					options.action = .links_add
				}
				'remove' {
					options.action = .links_remove
				}
				'--help', '-h', 'help' {
					return error('help')
				}
				else {
					return error('unknown plugins links command: ${action}')
				}
			}
		}
		else {
			return error('unknown plugins command: ${group}')
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
		.components_list, .links_list {
			if positional.len > 0 {
				return error('plugins list does not take positional arguments')
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
		.links_add {
			if positional.len != 1 {
				return error('plugins links add expects <absolute-package-path>')
			}
			options.path = positional[0]
		}
		.links_remove {
			if positional.len != 1 {
				return error('plugins links remove expects <name>')
			}
			options.name = positional[0]
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

fn execute_headless_plugins_links_list(port int, options HeadlessPluginsOptions) !string {
	response := headless_json_request(port, .get, '/v1/plugins/links', '', false, '')!
	if response.status_code != 200 {
		return error(headless_plugins_api_error(response))
	}
	if options.json {
		return response.body
	}
	catalog := json2.decode[PluginLinkCatalog](response.body)!
	mut lines := []string{cap: catalog.links.len + catalog.diagnostics.len + 2}
	lines << 'Plugin links (${catalog.links.len})'
	if catalog.links.len == 0 {
		lines << '(none)'
	}
	for link in catalog.links {
		lines << '${link.name}  ->  ${link.path}'
	}
	for diagnostic in catalog.diagnostics {
		lines << 'diagnostic  ${diagnostic.message}'
	}
	return lines.join('\n')
}

fn execute_headless_plugins_links_add(port int, options HeadlessPluginsOptions) !string {
	payload := PluginLinkInput{
		path: options.path
	}
	response := headless_json_request(port, .post, '/v1/plugins/links', json2.encode(payload),
		false, '')!
	if response.status_code != 200 {
		return error(headless_plugins_api_error(response))
	}
	if options.json {
		return response.body
	}
	link := json2.decode[PluginLink](response.body)!
	return 'Linked ${link.name}  ->  ${link.path}'
}

fn execute_headless_plugins_links_remove(port int, options HeadlessPluginsOptions) !string {
	path := '/v1/plugins/links/${urllib.path_escape(options.name)}'
	response := headless_json_request(port, .delete, path, '', false, '')!
	if response.status_code != 200 {
		return error(headless_plugins_api_error(response))
	}
	if options.json {
		return response.body
	}
	removal := json2.decode[PluginLinkRemoval](response.body)!
	return 'Removed plugin link ${removal.removed}'
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
		.links_list {
			execute_headless_plugins_links_list(port, options) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
		.links_add {
			execute_headless_plugins_links_add(port, options) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
		.links_remove {
			execute_headless_plugins_links_remove(port, options) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
	}
	println(output)
}
