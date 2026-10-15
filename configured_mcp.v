module main

import json2
import os
import sync

// Synthetic Agent Plugin name for operator-configured MCP servers that are not
// packaged as plugin.json. Trust and tool routing use configured/<server>.
// User scope: $VEASEL_DATA_DIR/mcp-servers.json (writable).
// Project scope: <workspace>/.veasel/mcp-servers.json (writable).
// Project-import: read-only portable mcpServers layouts verified from
// competitors — workspace-root .mcp.json (Claude Code / Copilot portable) and
// .cursor/mcp.json (Cursor project). .vscode/mcp.json uses a different
// top-level "servers" key and is not auto-imported.
// Precedence for the same configured/<name> (highest wins): project >
// project-import (.mcp.json then .cursor/mcp.json) > user. Agent Plugin
// servers stay namespaced as <plugin>/<server> and do not collide.
const configured_mcp_plugin_name = 'configured'
const max_configured_mcp_servers = 32
const max_configured_mcp_name_len = 64
const configured_mcp_scope_user = 'user'
const configured_mcp_scope_project = 'project'
const configured_mcp_scope_project_import = 'project-import'
const configured_mcp_import_mcp_json = '.mcp.json'
const configured_mcp_import_cursor = '.cursor/mcp.json'

struct PersistedConfiguredMCP {
mut:
	servers map[string]ConfiguredMCPServerSpec
}

// ConfiguredMCPServerSpec is the durable form of one operator-added MCP server.
// `disabled` defaults to false so older files without the field stay enabled.
struct ConfiguredMCPServerSpec {
pub:
	transport  string
	command    string
	args       []string
	cwd        string
	env        map[string]string
	url        string
	headers    map[string]string
	credential string @[omitempty]
	disabled   bool   @[omitempty]
}

pub struct ConfiguredMCPServerView {
pub:
	name         string
	scope        string = configured_mcp_scope_user
	config_file  string @[json: 'config_file'; omitempty]
	enabled      bool
	transport    string
	command      string   @[omitempty]
	args         []string @[omitempty]
	cwd          string   @[omitempty]
	env_keys     []string @[json: 'env_keys'; omitempty]
	url_origin   string   @[json: 'url_origin'; omitempty]
	header_names []string @[json: 'header_names'; omitempty]
	credential   string   @[omitempty]
}

pub struct ConfiguredMCPCatalog {
pub:
	scope        string = configured_mcp_scope_user
	path         string   @[omitempty]
	project_path string   @[json: 'project_path'; omitempty]
	import_paths []string @[json: 'import_paths'; omitempty]
	servers      []ConfiguredMCPServerView
}

struct ConfiguredMCPServerInput {
pub:
	name       string
	transport  string
	command    string
	args       []string
	cwd        string
	env        map[string]string
	url        string
	headers    map[string]string
	credential string
	enabled    bool   = true
	scope      string = configured_mcp_scope_user
	directory  string
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
	return state.view_scoped(configured_mcp_scope_user)
}

fn (mut state ConfiguredMCPState) view_scoped(scope string) ConfiguredMCPCatalog {
	state.mu.lock()
	defer {
		state.mu.unlock()
	}
	mut servers := []ConfiguredMCPServerView{cap: state.settings.servers.len}
	for name in state.settings.servers.keys().sorted() {
		spec := state.settings.servers[name]
		servers << configured_spec_view(name, spec, scope)
	}
	return ConfiguredMCPCatalog{
		scope:   scope
		path:    state.path
		servers: servers
	}
}

fn configured_spec_view(name string, spec ConfiguredMCPServerSpec, scope string) ConfiguredMCPServerView {
	return configured_spec_view_with_source(name, spec, scope, '')
}

fn configured_spec_view_with_source(name string, spec ConfiguredMCPServerSpec, scope string, config_file string) ConfiguredMCPServerView {
	resolved_scope := if scope.len > 0 { scope } else { configured_mcp_scope_user }
	resolved_file := if config_file.len > 0 {
		config_file
	} else {
		configured_mcp_source_for_scope(resolved_scope)
	}
	return ConfiguredMCPServerView{
		name:         name
		scope:        resolved_scope
		config_file:  resolved_file
		enabled:      !spec.disabled
		transport:    spec.transport
		command:      spec.command
		args:         spec.args
		cwd:          spec.cwd
		env_keys:     spec.env.keys().sorted()
		url_origin:   plugin_mcp_url_origin(spec.url)
		header_names: plugin_mcp_header_names(spec.headers)
		credential:   spec.credential
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
	return configured_spec_view(input.name, spec, configured_mcp_scope_user)
}

fn (mut state ConfiguredMCPState) upsert_scoped(input ConfiguredMCPServerInput, scope string) !ConfiguredMCPServerView {
	view := state.upsert(input)!
	return ConfiguredMCPServerView{
		name:         view.name
		scope:        scope
		config_file:  configured_mcp_source_for_scope(scope)
		enabled:      view.enabled
		transport:    view.transport
		command:      view.command
		args:         view.args
		cwd:          view.cwd
		env_keys:     view.env_keys
		url_origin:   view.url_origin
		header_names: view.header_names
		credential:   view.credential
	}
}

fn configured_mcp_source_for_scope(scope string) string {
	return match scope {
		configured_mcp_scope_project { os.join_path('.veasel', 'mcp-servers.json') }
		configured_mcp_scope_user { 'mcp-servers.json' }
		else { '' }
	}
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
		transport:  existing.transport
		command:    existing.command
		args:       existing.args
		cwd:        existing.cwd
		env:        existing.env
		url:        existing.url
		headers:    existing.headers
		credential: existing.credential
		disabled:   !enabled
	}
	mut servers := state.settings.servers.clone()
	servers[name] = spec
	updated := PersistedConfiguredMCP{
		servers: servers
	}
	state.persist(updated)!
	state.settings = updated
	return configured_spec_view(name, spec, configured_mcp_scope_user)
}

fn (mut state ConfiguredMCPState) set_enabled_scoped(name string, enabled bool, scope string) !ConfiguredMCPServerView {
	view := state.set_enabled(name, enabled)!
	return ConfiguredMCPServerView{
		name:         view.name
		scope:        scope
		config_file:  configured_mcp_source_for_scope(scope)
		enabled:      view.enabled
		transport:    view.transport
		command:      view.command
		args:         view.args
		cwd:          view.cwd
		env_keys:     view.env_keys
		url_origin:   view.url_origin
		header_names: view.header_names
		credential:   view.credential
	}
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
				if !valid_plugin_mcp_env_key(key) || value.contains('\0') {
					return error('env entries are invalid or use reserved names')
				}
				if plugin_mcp_env_key_conflicts(env, key) {
					return error('env entries must be unique regardless of case')
				}
				env[key] = value
			}
			cwd := input.cwd.trim_space()
			if cwd.len > 0 {
				if !os.is_abs_path(cwd) || os.is_link(cwd) || !os.is_dir(cwd) {
					return error('configured stdio cwd must be an absolute existing directory')
				}
			}
			if input.url.len > 0 || input.headers.len > 0 || input.credential.len > 0 {
				return error('stdio servers do not accept url, headers, or credential')
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
			credential := input.credential.trim_space()
			if credential.len > 0 && !is_valid_mcp_credential_name(credential) {
				return error('MCP credential name is invalid')
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
				transport:  transport
				url:        url
				headers:    headers
				credential: credential
				disabled:   !input.enabled
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

fn (app &App) materialize_configured_mcp_server(name string, spec ConfiguredMCPServerSpec) !PluginMCPServer {
	server := configured_spec_to_plugin_server(name, spec)!
	if spec.transport != 'streamable-http' || spec.credential.len == 0 {
		return server
	}
	mut credentials := app.mcp_credentials
	credential_headers := credentials.get_headers(spec.credential)!
	merged := merge_mcp_credential_headers(spec.headers, credential_headers)!
	return PluginMCPServer{
		name:        server.name
		transport:   server.transport
		url:         server.url
		headers:     merged
		plugin_name: server.plugin_name
	}
}

fn (app &App) get_configured_plugin_server(mut state ConfiguredMCPState, name string) !PluginMCPServer {
	state.mu.lock()
	spec := state.settings.servers[name] or {
		state.mu.unlock()
		return error('configured MCP server not found')
	}
	if spec.disabled {
		state.mu.unlock()
		return error('configured MCP server is disabled')
	}
	state.mu.unlock()
	return app.materialize_configured_mcp_server(name, spec)!
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
	mut scope := configured_mcp_scope_user
	mut directory := ''
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
	if scope_value := fields['scope'] {
		if scope_value !is string {
			return error('scope must be a string')
		}
		scope = (scope_value as string).trim_space()
		if scope.len == 0 {
			scope = configured_mcp_scope_user
		}
		if scope !in [configured_mcp_scope_user, configured_mcp_scope_project] {
			return error('scope must be user or project')
		}
	}
	if directory_value := fields['directory'] {
		if directory_value !is string {
			return error('directory must be a string')
		}
		directory = directory_value as string
	}
	mut credential := ''
	if credential_value := fields['credential'] {
		if credential_value !is string {
			return error('credential must be a string')
		}
		credential = credential_value as string
	}
	return ConfiguredMCPServerInput{
		name:       name_value as string
		transport:  transport_value as string
		command:    command
		args:       args
		cwd:        cwd
		env:        env
		url:        url
		headers:    headers
		credential: credential
		enabled:    enabled
		scope:      scope
		directory:  directory
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
		description: 'Operator-configured MCP servers from VEASEL_DATA_DIR and optional <workspace>/.veasel (not an Agent Plugin package).'
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

fn project_configured_mcp_path(workspace string) string {
	if workspace.len == 0 {
		return ''
	}
	return os.join_path(workspace, '.veasel', 'mcp-servers.json')
}

fn normalize_configured_mcp_scope(scope string) !string {
	trimmed := scope.trim_space()
	if trimmed.len == 0 || trimmed == configured_mcp_scope_user {
		return configured_mcp_scope_user
	}
	if trimmed == configured_mcp_scope_project {
		return configured_mcp_scope_project
	}
	return error('scope must be user or project')
}

fn resolve_configured_mcp_workspace(directory string) !string {
	trimmed := directory.trim_space()
	if trimmed.len == 0 {
		return error('project-scoped MCP requires an absolute workspace directory')
	}
	return canonical_project_directory(trimmed)!
}

// merge_configured_plugin_servers overlays layers from lowest to highest
// precedence. Later layers replace the same server name.
fn merge_configured_plugin_servers(layers [][]PluginMCPServer) []PluginMCPServer {
	mut by_name := map[string]PluginMCPServer{}
	for layer in layers {
		for server in layer {
			by_name[server.name] = server
		}
	}
	mut merged := []PluginMCPServer{cap: by_name.len}
	for name in by_name.keys().sorted() {
		merged << by_name[name]
	}
	return merged
}

fn configured_mcp_string_contains_unexpanded(value string) bool {
	return value.contains(r'${')
}

fn configured_mcp_map_contains_unexpanded(values map[string]string) bool {
	for key, value in values {
		if configured_mcp_string_contains_unexpanded(key)
			|| configured_mcp_string_contains_unexpanded(value) {
			return true
		}
	}
	return false
}

fn parse_imported_mcp_servers_document(raw string, source string) ([]ConfiguredMCPServerView, []PluginMCPServer) {
	empty_views := []ConfiguredMCPServerView{}
	empty_servers := []PluginMCPServer{}
	fields := json2.decode[map[string]json2.Any](raw) or { return empty_views, empty_servers }
	servers_value := fields['mcpServers'] or { return empty_views, empty_servers }
	if servers_value !is map[string]json2.Any {
		return empty_views, empty_servers
	}
	mut views := []ConfiguredMCPServerView{}
	mut plugin_servers := []PluginMCPServer{}
	for name in (servers_value as map[string]json2.Any).keys().sorted() {
		if !is_valid_configured_mcp_name(name) {
			continue
		}
		entry := (servers_value as map[string]json2.Any)[name] or { continue }
		input := decode_imported_mcp_server_entry(name, entry) or { continue }
		mut has_unexpanded := configured_mcp_string_contains_unexpanded(input.command)
			|| configured_mcp_string_contains_unexpanded(input.cwd)
			|| configured_mcp_string_contains_unexpanded(input.url)
			|| configured_mcp_map_contains_unexpanded(input.env)
			|| configured_mcp_map_contains_unexpanded(input.headers)
		if !has_unexpanded {
			for argument in input.args {
				if configured_mcp_string_contains_unexpanded(argument) {
					has_unexpanded = true
					break
				}
			}
		}
		if has_unexpanded {
			continue
		}
		spec := parse_configured_mcp_input(input) or { continue }
		server := configured_spec_to_plugin_server(name, spec) or { continue }
		views << configured_spec_view_with_source(name, spec, configured_mcp_scope_project_import,
			source)
		plugin_servers << server
	}
	return views, plugin_servers
}

fn decode_imported_mcp_server_entry(name string, value json2.Any) !ConfiguredMCPServerInput {
	if value !is map[string]json2.Any {
		return error('imported MCP server must be an object')
	}
	fields := value as map[string]json2.Any
	mut transport := ''
	if type_value := fields['type'] {
		if type_value !is string {
			return error('type must be a string')
		}
		transport = (type_value as string).trim_space()
	}
	mut command := ''
	mut args := []string{}
	mut cwd := ''
	mut env := map[string]string{}
	mut url := ''
	mut headers := map[string]string{}
	if command_value := fields['command'] {
		if command_value !is string {
			return error('command must be a string')
		}
		command = command_value as string
	}
	if url_value := fields['url'] {
		if url_value !is string {
			return error('url must be a string')
		}
		url = url_value as string
	}
	if transport.len == 0 {
		if command.len > 0 {
			transport = 'stdio'
		} else if url.len > 0 {
			transport = 'streamable-http'
		} else {
			return error('imported MCP server needs command or url')
		}
	}
	match transport {
		'stdio' {}
		'http' {
			transport = 'streamable-http'
		}
		'streamable-http' {}
		else {
			return error('unsupported imported MCP transport')
		}
	}
	if args_value := fields['args'] {
		if args_value !is []json2.Any {
			return error('args must be an array of strings')
		}
		for item in args_value as []json2.Any {
			if item !is string {
				return error('args must be an array of strings')
			}
			args << item as string
		}
	}
	if cwd_value := fields['cwd'] {
		if cwd_value !is string {
			return error('cwd must be a string')
		}
		cwd = cwd_value as string
	}
	if env_value := fields['env'] {
		if env_value !is map[string]json2.Any {
			return error('env must be an object of strings')
		}
		for key, item in env_value as map[string]json2.Any {
			if item !is string {
				return error('env must be an object of strings')
			}
			env[key] = item as string
		}
	}
	if headers_value := fields['headers'] {
		if headers_value !is map[string]json2.Any {
			return error('headers must be an object of strings')
		}
		for key, item in headers_value as map[string]json2.Any {
			if item !is string {
				return error('headers must be an object of strings')
			}
			headers[key] = item as string
		}
	}
	return ConfiguredMCPServerInput{
		name:      name
		transport: transport
		command:   command
		args:      args
		cwd:       cwd
		env:       env
		url:       url
		headers:   headers
		enabled:   true
		scope:     configured_mcp_scope_project_import
	}
}

fn load_imported_project_mcp(workspace string) ([]ConfiguredMCPServerView, []PluginMCPServer, []string) {
	mut views := []ConfiguredMCPServerView{}
	mut plugin_servers := []PluginMCPServer{}
	mut import_paths := []string{}
	// Lower precedence first so .mcp.json overlays .cursor/mcp.json when both
	// define the same name in the import layer (portable layout wins).
	for relative in [configured_mcp_import_cursor, configured_mcp_import_mcp_json] {
		path := os.join_path(workspace, relative)
		if !os.is_file(path) {
			continue
		}
		raw := os.read_file(path) or { continue }
		file_views, file_servers := parse_imported_mcp_servers_document(raw, relative)
		if file_views.len == 0 && file_servers.len == 0 {
			// Still record the path so operators can see we considered it.
			import_paths << path
			continue
		}
		import_paths << path
		views << file_views
		plugin_servers << file_servers
	}
	return views, plugin_servers, import_paths
}

fn find_imported_project_mcp_server(workspace string, server_name string) ?PluginMCPServer {
	// Highest import precedence first for trust resolution.
	for relative in [configured_mcp_import_mcp_json, configured_mcp_import_cursor] {
		path := os.join_path(workspace, relative)
		if !os.is_file(path) {
			continue
		}
		raw := os.read_file(path) or { continue }
		_, servers := parse_imported_mcp_servers_document(raw, relative)
		for server in servers {
			if server.name == server_name {
				return server
			}
		}
	}
	return none
}

fn promote_configured_mcp_stdio_root(app &App, server PluginMCPServer) !(string, PluginMCPServer) {
	mut root := app.configured_mcp_package_root(server.name)
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

fn (app &App) list_configured_mcp_catalog(workspace string) ConfiguredMCPCatalog {
	mut user_state := app.configured_mcp
	user := user_state.view_scoped(configured_mcp_scope_user)
	mut servers := user.servers.clone()
	mut project_path := ''
	mut import_paths := []string{}
	mut catalog_scope := configured_mcp_scope_user
	if workspace.trim_space().len > 0 {
		if resolved := resolve_configured_mcp_workspace(workspace) {
			project_path = project_configured_mcp_path(resolved)
			mut project_state := new_configured_mcp_state(project_path)
			project := project_state.view_scoped(configured_mcp_scope_project)
			imported_views, _, found_imports := load_imported_project_mcp(resolved)
			import_paths = found_imports.clone()
			servers << imported_views
			servers << project.servers
			if project.servers.len > 0 || os.is_file(project_path) || imported_views.len > 0
				|| found_imports.len > 0 {
				catalog_scope = 'mixed'
			}
		}
	}
	// Stable order: name, then scope (user < project-import < project).
	mut by_key := map[string]ConfiguredMCPServerView{}
	mut keys := []string{}
	for server in servers {
		key := server.name + '/' + server.scope + '/' + server.config_file // field access, not a string prefix
		if key in by_key {
			continue
		}
		by_key[key] = server
		keys << key
	}
	keys.sort()
	mut ordered := []ConfiguredMCPServerView{cap: keys.len}
	for key in keys {
		ordered << by_key[key]
	}
	return ConfiguredMCPCatalog{
		scope:        catalog_scope
		path:         user.path
		project_path: project_path
		import_paths: import_paths
		servers:      ordered
	}
}

fn (app &App) configured_mcp_state_for_scope(scope string, directory string) !&ConfiguredMCPState {
	resolved_scope := normalize_configured_mcp_scope(scope)!
	if resolved_scope == configured_mcp_scope_user {
		return app.configured_mcp
	}
	workspace := resolve_configured_mcp_workspace(directory)!
	path := project_configured_mcp_path(workspace)
	return new_configured_mcp_state(path)
}

fn (app &App) find_session_mcp_server(plugin_name string, server_name string, workspace string) !(string, PluginMCPServer) {
	if plugin_name == configured_mcp_plugin_name {
		if workspace.trim_space().len > 0 {
			if resolved := resolve_configured_mcp_workspace(workspace) {
				mut project_state := new_configured_mcp_state(project_configured_mcp_path(resolved))
				if server := app.get_configured_plugin_server(mut project_state, server_name) {
					return promote_configured_mcp_stdio_root(app, server)!
				}
				if imported := find_imported_project_mcp_server(resolved, server_name) {
					return promote_configured_mcp_stdio_root(app, imported)!
				}
			}
		}
		mut state := app.configured_mcp
		server := app.get_configured_plugin_server(mut state, server_name)!
		return promote_configured_mcp_stdio_root(app, server)!
	}
	mut components := app.plugin_components
	if !components.is_enabled(plugin_name, plugin_component_kind_mcp, server_name) {
		return error('MCP server is disabled')
	}
	return find_agent_mcp_server(app.plugin_directory, plugin_name, server_name)
}

fn (app &App) plugin_catalog_for_directory(project_directory string) !PluginCatalog {
	catalog := discover_agent_plugins_with_standalone(app.plugin_directory, project_directory)!
	mut user_state := app.configured_mcp
	user_servers := user_state.list_plugin_servers()
	mut project_servers := []PluginMCPServer{}
	mut import_servers := []PluginMCPServer{}
	if project_directory.trim_space().len > 0 {
		if resolved := resolve_configured_mcp_workspace(project_directory) {
			mut project_state := new_configured_mcp_state(project_configured_mcp_path(resolved))
			project_servers = project_state.list_plugin_servers()
			_, import_servers, _ = load_imported_project_mcp(resolved)
		}
	}
	// Precedence (lowest → highest): user, project-import, project.
	merged := merge_configured_plugin_servers([user_servers, import_servers, project_servers])
	with_configured := merge_configured_mcp_into_catalog(catalog, merged)
	mut components := app.plugin_components
	return apply_plugin_component_state(with_configured, mut components)
}
