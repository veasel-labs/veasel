module main

import json2
import os
import sync

// Synthetic Agent Plugin name for operator-configured MCP servers that are not
// packaged as plugin.json. Trust and tool routing use configured/<server>.
// Configurations persist under $VEASEL_DATA_DIR/mcp-servers.json (user scope).
const configured_mcp_plugin_name = 'configured'
const max_configured_mcp_servers = 32
const max_configured_mcp_name_len = 64

struct PersistedConfiguredMCP {
mut:
	servers map[string]ConfiguredMCPServerSpec
}

// ConfiguredMCPServerSpec is the durable form of one operator-added MCP server.
// `disabled` defaults to false so older files without the field stay enabled.
struct ConfiguredMCPServerSpec {
pub:
	transport string
	command   string
	args      []string
	cwd       string
	env       map[string]string
	url       string
	headers   map[string]string
	disabled  bool @[omitempty]
}

pub struct ConfiguredMCPServerView {
pub:
	name         string
	scope        string = 'user'
	enabled      bool
	transport    string
	command      string   @[omitempty]
	args         []string @[omitempty]
	cwd          string   @[omitempty]
	env_keys     []string @[json: 'env_keys'; omitempty]
	url_origin   string   @[json: 'url_origin'; omitempty]
	header_names []string @[json: 'header_names'; omitempty]
}

pub struct ConfiguredMCPCatalog {
pub:
	scope   string = 'user'
	path    string @[omitempty]
	servers []ConfiguredMCPServerView
}

struct ConfiguredMCPServerInput {
pub:
	name      string
	transport string
	command   string
	args      []string
	cwd       string
	env       map[string]string
	url       string
	headers   map[string]string
	enabled   bool = true
}

struct ConfiguredMCPEnableInput {
pub:
	enabled bool
}

pub struct ConfiguredMCPRemoval {
pub:
	removed string
}

@[heap]
pub struct ConfiguredMCPState {
mut:
	mu       sync.Mutex
	path     string
	settings PersistedConfiguredMCP
}

fn new_configured_mcp_state(path string) &ConfiguredMCPState {
	mut state := &ConfiguredMCPState{
		path:     path
		settings: PersistedConfiguredMCP{
			servers: map[string]ConfiguredMCPServerSpec{}
		}
	}
	if path != '' && os.is_file(path) {
		loaded := json2.decode[PersistedConfiguredMCP](os.read_file(path) or { '' }) or {
			return state
		}
		mut servers := map[string]ConfiguredMCPServerSpec{}
		for name, spec in loaded.servers {
			if !is_valid_configured_mcp_name(name) {
				continue
			}
			_ := configured_spec_to_plugin_server(name, spec) or { continue }
			servers[name] = spec
		}
		state.settings.servers = servers
	}
	return state
}

fn (store &Store) configured_mcp_path() string {
	if store.path == ':memory:' {
		return ''
	}
	return os.join_path(os.dir(store.path), 'mcp-servers.json')
}

fn is_valid_configured_mcp_name(name string) bool {
	if name.len < 1 || name.len > max_configured_mcp_name_len || name == configured_mcp_plugin_name {
		return false
	}
	if name[0] !in `a` .. `z` && name[0] !in `0` .. `9` {
		return false
	}
	if name[name.len - 1] !in `a` .. `z` && name[name.len - 1] !in `0` .. `9` {
		return false
	}
	if name.contains('--') || name.contains('..') {
		return false
	}
	for c in name {
		if c !in `a` .. `z` && c !in `0` .. `9` && c !in [`-`, `.`] {
			return false
		}
	}
	return true
}

fn (mut state ConfiguredMCPState) view() ConfiguredMCPCatalog {
	state.mu.lock()
	defer {
		state.mu.unlock()
	}
	mut servers := []ConfiguredMCPServerView{cap: state.settings.servers.len}
	for name in state.settings.servers.keys().sorted() {
		spec := state.settings.servers[name]
		servers << configured_spec_view(name, spec)
	}
	return ConfiguredMCPCatalog{
		scope:   'user'
		path:    state.path
		servers: servers
	}
}

fn configured_spec_view(name string, spec ConfiguredMCPServerSpec) ConfiguredMCPServerView {
	return ConfiguredMCPServerView{
		name:         name
		scope:        'user'
		enabled:      !spec.disabled
		transport:    spec.transport
		command:      spec.command
		args:         spec.args
		cwd:          spec.cwd
		env_keys:     spec.env.keys().sorted()
		url_origin:   plugin_mcp_url_origin(spec.url)
		header_names: plugin_mcp_header_names(spec.headers)
	}
}

fn (mut state ConfiguredMCPState) list_plugin_servers() []PluginMCPServer {
	state.mu.lock()
	defer {
		state.mu.unlock()
	}
	mut servers := []PluginMCPServer{cap: state.settings.servers.len}
	for name in state.settings.servers.keys().sorted() {
		spec := state.settings.servers[name]
		if spec.disabled {
			continue
		}
		server := configured_spec_to_plugin_server(name, spec) or { continue }
		servers << server
	}
	return servers
}

fn (mut state ConfiguredMCPState) get_plugin_server(name string) !PluginMCPServer {
	state.mu.lock()
	defer {
		state.mu.unlock()
	}
	spec := state.settings.servers[name] or { return error('configured MCP server not found') }
	if spec.disabled {
		return error('configured MCP server is disabled')
	}
	return configured_spec_to_plugin_server(name, spec)!
}

fn (mut state ConfiguredMCPState) upsert(input ConfiguredMCPServerInput) !ConfiguredMCPServerView {
	state.mu.lock()
	defer {
		state.mu.unlock()
	}
	if !is_valid_configured_mcp_name(input.name) {
		return error('configured MCP server name is invalid')
	}
	if state.settings.servers.len >= max_configured_mcp_servers
		&& input.name !in state.settings.servers {
		return error('configured MCP server limit (${max_configured_mcp_servers}) reached')
	}
	spec := parse_configured_mcp_input(input)!
	_ := configured_spec_to_plugin_server(input.name, spec)!
	mut servers := state.settings.servers.clone()
	servers[input.name] = spec
	updated := PersistedConfiguredMCP{
		servers: servers
	}
	state.persist(updated)!
	state.settings = updated
	return configured_spec_view(input.name, spec)
}

fn (mut state ConfiguredMCPState) set_enabled(name string, enabled bool) !ConfiguredMCPServerView {
	state.mu.lock()
	defer {
		state.mu.unlock()
	}
	if !is_valid_configured_mcp_name(name) {
		return error('configured MCP server name is invalid')
	}
	existing := state.settings.servers[name] or { return error('configured MCP server not found') }
	spec := ConfiguredMCPServerSpec{
		transport: existing.transport
		command:   existing.command
		args:      existing.args
		cwd:       existing.cwd
		env:       existing.env
		url:       existing.url
		headers:   existing.headers
		disabled:  !enabled
	}
	mut servers := state.settings.servers.clone()
	servers[name] = spec
	updated := PersistedConfiguredMCP{
		servers: servers
	}
	state.persist(updated)!
	state.settings = updated
	return configured_spec_view(name, spec)
}

fn (mut state ConfiguredMCPState) remove(name string) ! {
	state.mu.lock()
	defer {
		state.mu.unlock()
	}
	if !is_valid_configured_mcp_name(name) {
		return error('configured MCP server name is invalid')
	}
	if name !in state.settings.servers {
		return error('configured MCP server not found')
	}
	mut servers := state.settings.servers.clone()
	servers.delete(name)
	updated := PersistedConfiguredMCP{
		servers: servers
	}
	state.persist(updated)!
	state.settings = updated
}

fn (state &ConfiguredMCPState) persist(settings PersistedConfiguredMCP) ! {
	if state.path == '' {
		return
	}
	os.mkdir_all(os.dir(state.path))!
	temporary_path := '${state.path}.tmp'
	write_private_file(temporary_path, json2.encode(settings))!
	$if !windows {
		os.chmod(temporary_path, 0o600)!
	}
	os.mv(temporary_path, state.path)!
}

fn parse_configured_mcp_input(input ConfiguredMCPServerInput) !ConfiguredMCPServerSpec {
	transport := input.transport.trim_space()
	match transport {
		'stdio' {
			command := input.command.trim_space()
			if command.len == 0 || command.contains('\0') || command.contains('\n')
				|| command.contains('\r') {
				return error('stdio command must be one executable token')
			}
			if command.starts_with('./') || command.starts_with('.\\') {
				return error('configured stdio command must be a bare name or absolute path')
			}
			if command.contains('/') || command.contains('\\') {
				if !os.is_abs_path(command) {
					return error('configured stdio command path must be absolute')
				}
				if os.is_link(command) || !os.is_file(command) {
					return error('configured stdio command must be an existing regular file')
				}
			}
			if input.args.len > max_plugin_mcp_args {
				return error('args exceeds the ${max_plugin_mcp_args} entry limit')
			}
			mut args := []string{}
			for argument in input.args {
				if argument.contains('\0') {
					return error('arguments must not contain NUL bytes')
				}
				args << argument
			}
			if input.env.len > max_plugin_mcp_env {
				return error('env exceeds the ${max_plugin_mcp_env} entry limit')
			}
			mut env := map[string]string{}
			for key, value in input.env {
				if key.len == 0 || key.contains('=') || key.contains('\0')
					|| key.to_upper() in ['PLUGIN_ROOT', 'PLUGIN_DATA'] || value.contains('\0') {
					return error('env entries are invalid or use reserved names')
				}
				env[key] = value
			}
			cwd := input.cwd.trim_space()
			if cwd.len > 0 {
				if !os.is_abs_path(cwd) || os.is_link(cwd) || !os.is_dir(cwd) {
					return error('configured stdio cwd must be an absolute existing directory')
				}
			}
			if input.url.len > 0 || input.headers.len > 0 {
				return error('stdio servers do not accept url or headers')
			}
			return ConfiguredMCPServerSpec{
				transport: transport
				command:   command
				args:      args
				cwd:       cwd
				env:       env
				disabled:  !input.enabled
			}
		}
		'streamable-http' {
			if input.command.len > 0 || input.args.len > 0 || input.cwd.len > 0 || input.env.len > 0 {
				return error('HTTP MCP servers do not accept command, args, cwd, or env')
			}
			url := validate_plugin_mcp_url(input.url.trim_space())!
			if input.headers.len > max_plugin_mcp_headers {
				return error('headers exceeds the ${max_plugin_mcp_headers} entry limit')
			}
			mut headers := map[string]string{}
			for key, value in input.headers {
				if !valid_http_header(key, value) {
					return error('HTTP header is invalid')
				}
				for existing, _ in headers {
					if existing.to_lower() == key.to_lower() {
						return error('HTTP header names must be unique regardless of case')
					}
				}
				headers[key] = value
			}
			return ConfiguredMCPServerSpec{
				transport: transport
				url:       url
				headers:   headers
				disabled:  !input.enabled
			}
		}
		else {
			return error('configured MCP transport must be stdio or streamable-http')
		}
	}
}

fn configured_spec_to_plugin_server(name string, spec ConfiguredMCPServerSpec) !PluginMCPServer {
	match spec.transport {
		'stdio' {
			return PluginMCPServer{
				name:        name
				transport:   'stdio'
				command:     spec.command
				args:        spec.args
				cwd:         spec.cwd
				env:         spec.env
				plugin_name: configured_mcp_plugin_name
			}
		}
		'streamable-http' {
			url := validate_plugin_mcp_url(spec.url)!
			return PluginMCPServer{
				name:        name
				transport:   'streamable-http'
				url:         url
				headers:     spec.headers
				plugin_name: configured_mcp_plugin_name
			}
		}
		else {
			return error('unsupported configured MCP transport')
		}
	}
}

fn decode_configured_mcp_input(raw string) !ConfiguredMCPServerInput {
	fields := json2.decode[map[string]json2.Any](raw) or {
		return error('Expected configured MCP server fields')
	}
	name_value := fields['name'] or { return error('Expected name and transport fields') }
	transport_value := fields['transport'] or { return error('Expected name and transport fields') }
	if name_value !is string || transport_value !is string {
		return error('Expected name and transport fields')
	}
	mut command := ''
	mut cwd := ''
	mut url := ''
	mut args := []string{}
	mut env := map[string]string{}
	mut headers := map[string]string{}
	mut enabled := true
	if command_value := fields['command'] {
		if command_value !is string {
			return error('command must be a string')
		}
		command = command_value as string
	}
	if cwd_value := fields['cwd'] {
		if cwd_value !is string {
			return error('cwd must be a string')
		}
		cwd = cwd_value as string
	}
	if url_value := fields['url'] {
		if url_value !is string {
			return error('url must be a string')
		}
		url = url_value as string
	}
	if args_value := fields['args'] {
		if args_value !is []json2.Any {
			return error('args must be an array of strings')
		}
		for arg in args_value as []json2.Any {
			if arg !is string {
				return error('args must be an array of strings')
			}
			args << arg as string
		}
	}
	if env_value := fields['env'] {
		if env_value !is map[string]json2.Any {
			return error('env must be an object of strings')
		}
		for key, value in env_value as map[string]json2.Any {
			if value !is string {
				return error('env must be an object of strings')
			}
			env[key] = value as string
		}
	}
	if headers_value := fields['headers'] {
		if headers_value !is map[string]json2.Any {
			return error('headers must be an object of strings')
		}
		for key, value in headers_value as map[string]json2.Any {
			if value !is string {
				return error('headers must be an object of strings')
			}
			headers[key] = value as string
		}
	}
	if enabled_value := fields['enabled'] {
		if enabled_value !is bool {
			return error('enabled must be a boolean')
		}
		enabled = enabled_value as bool
	}
	return ConfiguredMCPServerInput{
		name:      name_value as string
		transport: transport_value as string
		command:   command
		args:      args
		cwd:       cwd
		env:       env
		url:       url
		headers:   headers
		enabled:   enabled
	}
}

fn decode_configured_mcp_enable_input(raw string) !ConfiguredMCPEnableInput {
	fields := json2.decode[map[string]json2.Any](raw) or {
		return error('Expected enabled field')
	}
	enabled_value := fields['enabled'] or { return error('Expected enabled field') }
	if enabled_value !is bool {
		return error('Expected enabled field')
	}
	return ConfiguredMCPEnableInput{
		enabled: enabled_value as bool
	}
}

fn merge_configured_mcp_into_catalog(catalog PluginCatalog, servers []PluginMCPServer) PluginCatalog {
	if servers.len == 0 {
		return catalog
	}
	mut mcp_servers := []PluginMCPServerSummary{cap: servers.len}
	for server in servers {
		mcp_servers << PluginMCPServerSummary{
			name:         server.name
			transport:    server.transport
			command:      server.command
			url_origin:   plugin_mcp_url_origin(server.url)
			header_count: server.headers.len
			header_names: plugin_mcp_header_names(server.headers)
		}
	}
	mut plugins := catalog.plugins.clone()
	mut diagnostics := catalog.diagnostics.clone()
	for plugin in catalog.plugins {
		if plugin.name == configured_mcp_plugin_name {
			diagnostics << PluginDiagnostic{
				component: configured_mcp_plugin_name
				message:   'Skipping operator-configured MCP catalog entry because an Agent Plugin already uses the reserved name `configured`'
			}
			return PluginCatalog{
				plugins:     plugins
				diagnostics: diagnostics
			}
		}
	}
	plugins << PluginCatalogEntry{
		name:        configured_mcp_plugin_name
		version:     '1'
		description: 'Operator-configured MCP servers persisted under VEASEL_DATA_DIR (user scope; not an Agent Plugin package).'
		skills:      []PluginSkillSummary{}
		mcp_servers: mcp_servers
		diagnostics: []PluginDiagnostic{}
		origin:      'configured'
	}
	return PluginCatalog{
		plugins:     plugins
		diagnostics: diagnostics
	}
}

fn (app &App) configured_mcp_package_root(server_name string) string {
	return os.join_path(app.plugin_data_directory, configured_mcp_plugin_name, server_name)
}

fn (app &App) find_session_mcp_server(plugin_name string, server_name string) !(string, PluginMCPServer) {
	if plugin_name == configured_mcp_plugin_name {
		mut state := app.configured_mcp
		server := state.get_plugin_server(server_name)!
		mut root := app.configured_mcp_package_root(server_name)
		os.mkdir_all(root)!
		// Absolute cwd is stored on the spec for display/persistence. The stdio
		// transport only accepts plugin-relative cwd tokens, so promote the
		// absolute directory to PLUGIN_ROOT and clear the server cwd.
		if server.transport == 'stdio' && server.cwd.len > 0 {
			root = server.cwd
			return root, PluginMCPServer{
				name:        server.name
				transport:   server.transport
				command:     server.command
				args:        server.args
				cwd:         ''
				env:         server.env
				plugin_name: server.plugin_name
			}
		}
		return root, server
	}
	return find_agent_mcp_server(app.plugin_directory, plugin_name, server_name)
}

fn (app &App) plugin_catalog_for_directory(project_directory string) !PluginCatalog {
	catalog := discover_agent_plugins_with_standalone(app.plugin_directory, project_directory)!
	mut state := app.configured_mcp
	return merge_configured_mcp_into_catalog(catalog, state.list_plugin_servers())
}
