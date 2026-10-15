module main

import json2
import os
import sync

const plugin_component_kind_skill = 'skill'
const plugin_component_kind_mcp = 'mcp'
const max_plugin_component_plugins = 128

struct PersistedPluginComponents {
mut:
	plugins map[string]PersistedPluginComponentSet
}

struct PersistedPluginComponentSet {
mut:
	skills      map[string]bool
	mcp_servers map[string]bool @[json: 'mcp_servers']
}

pub struct PluginComponentView {
pub:
	plugin  string
	kind    string
	name    string
	enabled bool
}

pub struct PluginComponentCatalog {
pub:
	path       string @[omitempty]
	components []PluginComponentView
}

struct PluginComponentToggleInput {
pub:
	plugin  string
	kind    string
	name    string
	enabled bool = true
}

@[heap]
pub struct PluginComponentState {
mut:
	mu       sync.Mutex
	path     string
	settings PersistedPluginComponents
}

fn new_plugin_component_state(path string) &PluginComponentState {
	mut state := &PluginComponentState{
		path:     path
		settings: PersistedPluginComponents{
			plugins: map[string]PersistedPluginComponentSet{}
		}
	}
	if path != '' && os.is_file(path) {
		loaded := json2.decode[PersistedPluginComponents](os.read_file(path) or { '' }) or {
			return state
		}
		mut plugins := map[string]PersistedPluginComponentSet{}
		for plugin_name, set in loaded.plugins {
			if !is_valid_plugin_component_plugin_name(plugin_name) {
				continue
			}
			mut skills := map[string]bool{}
			for skill_name, enabled in set.skills {
				if is_valid_plugin_component_entry_name(skill_name) {
					skills[skill_name] = enabled
				}
			}
			mut servers := map[string]bool{}
			for server_name, enabled in set.mcp_servers {
				if is_valid_plugin_component_entry_name(server_name) {
					servers[server_name] = enabled
				}
			}
			plugins[plugin_name] = PersistedPluginComponentSet{
				skills:      skills
				mcp_servers: servers
			}
		}
		state.settings.plugins = plugins
	}
	return state
}

fn (store &Store) plugin_components_path() string {
	if store.path == ':memory:' {
		return ''
	}
	return os.join_path(os.dir(store.path), 'plugin-components.json')
}

fn is_valid_plugin_component_plugin_name(name string) bool {
	return is_valid_configured_mcp_name(name) || (name.len > 0 && name.len <= 64
		&& !plugin_component_name_has_unsafe_bytes(name))
}

fn is_valid_plugin_component_entry_name(name string) bool {
	return name.len > 0 && name.len <= 256 && !plugin_component_name_has_unsafe_bytes(name)
}

fn plugin_component_name_has_unsafe_bytes(name string) bool {
	if name.contains('/') || name.contains('\\') {
		return true
	}
	for c in name {
		if c < 32 || c == 127 {
			return true
		}
	}
	return false
}

fn (mut state PluginComponentState) is_enabled(plugin string, kind string, name string) bool {
	state.mu.lock()
	defer {
		state.mu.unlock()
	}
	set := state.settings.plugins[plugin] or { return true }
	match kind {
		plugin_component_kind_skill {
			if name in set.skills {
				return set.skills[name]
			}
		}
		plugin_component_kind_mcp {
			if name in set.mcp_servers {
				return set.mcp_servers[name]
			}
		}
		else {}
	}
	return true
}

fn (mut state PluginComponentState) view() PluginComponentCatalog {
	state.mu.lock()
	defer {
		state.mu.unlock()
	}
	mut components := []PluginComponentView{}
	for plugin_name in state.settings.plugins.keys().sorted() {
		set := state.settings.plugins[plugin_name]
		for skill_name in set.skills.keys().sorted() {
			components << PluginComponentView{
				plugin:  plugin_name
				kind:    plugin_component_kind_skill
				name:    skill_name
				enabled: set.skills[skill_name]
			}
		}
		for server_name in set.mcp_servers.keys().sorted() {
			components << PluginComponentView{
				plugin:  plugin_name
				kind:    plugin_component_kind_mcp
				name:    server_name
				enabled: set.mcp_servers[server_name]
			}
		}
	}
	return PluginComponentCatalog{
		path:       state.path
		components: components
	}
}

fn (mut state PluginComponentState) set_enabled(input PluginComponentToggleInput) !PluginComponentView {
	state.mu.lock()
	defer {
		state.mu.unlock()
	}
	if !is_valid_plugin_component_plugin_name(input.plugin) {
		return error('plugin name is invalid')
	}
	if input.kind !in [plugin_component_kind_skill, plugin_component_kind_mcp] {
		return error('kind must be skill or mcp')
	}
	if !is_valid_plugin_component_entry_name(input.name) {
		return error('component name is invalid')
	}
	mut plugins := state.settings.plugins.clone()
	mut set := plugins[input.plugin] or {
		PersistedPluginComponentSet{
			skills:      map[string]bool{}
			mcp_servers: map[string]bool{}
		}
	}
	if plugins.len >= max_plugin_component_plugins && input.plugin !in plugins {
		return error('plugin component limit (${max_plugin_component_plugins}) reached')
	}
	match input.kind {
		plugin_component_kind_skill {
			mut skills := set.skills.clone()
			if input.enabled {
				skills.delete(input.name)
			} else {
				skills[input.name] = false
			}
			set.skills = skills
		}
		plugin_component_kind_mcp {
			mut servers := set.mcp_servers.clone()
			if input.enabled {
				servers.delete(input.name)
			} else {
				servers[input.name] = false
			}
			set.mcp_servers = servers
		}
		else {}
	}
	if set.skills.len == 0 && set.mcp_servers.len == 0 {
		plugins.delete(input.plugin)
	} else {
		plugins[input.plugin] = set
	}
	updated := PersistedPluginComponents{
		plugins: plugins
	}
	state.persist(updated)!
	state.settings = updated
	return PluginComponentView{
		plugin:  input.plugin
		kind:    input.kind
		name:    input.name
		enabled: input.enabled
	}
}

fn (state &PluginComponentState) persist(settings PersistedPluginComponents) ! {
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

fn decode_plugin_component_toggle_input(raw string) !PluginComponentToggleInput {
	fields := json2.decode[map[string]json2.Any](raw) or {
		return error('Expected plugin, kind, name, and enabled fields')
	}
	plugin_value := fields['plugin'] or { return error('Expected plugin field') }
	kind_value := fields['kind'] or { return error('Expected kind field') }
	name_value := fields['name'] or { return error('Expected name field') }
	enabled_value := fields['enabled'] or { return error('Expected enabled field') }
	if plugin_value !is string || kind_value !is string || name_value !is string
		|| enabled_value !is bool {
		return error('plugin, kind, and name must be strings; enabled must be a boolean')
	}
	plugin := plugin_value as string
	name := name_value as string
	if !is_valid_plugin_component_plugin_name(plugin) {
		return error('plugin component plugin name is invalid')
	}
	if !is_valid_plugin_component_entry_name(name) {
		return error('plugin component entry name is invalid')
	}
	return PluginComponentToggleInput{
		plugin:  plugin
		kind:    kind_value as string
		name:    name
		enabled: enabled_value as bool
	}
}

fn apply_plugin_component_state(catalog PluginCatalog, mut state PluginComponentState) PluginCatalog {
	mut plugins := []PluginCatalogEntry{cap: catalog.plugins.len}
	for plugin in catalog.plugins {
		mut skills := []PluginSkillSummary{cap: plugin.skills.len}
		for skill in plugin.skills {
			skills << PluginSkillSummary{
				name:                   skill.name
				description:            skill.description
				allowed_tools_declared: skill.allowed_tools_declared
				allowed_tools:          skill.allowed_tools
				source:                 skill.source
				scope:                  skill.scope
				enabled:                state.is_enabled(plugin.name, plugin_component_kind_skill,
					skill.name)
			}
		}
		mut mcp_servers := []PluginMCPServerSummary{cap: plugin.mcp_servers.len}
		for server in plugin.mcp_servers {
			mcp_servers << PluginMCPServerSummary{
				name:         server.name
				transport:    server.transport
				command:      server.command
				url_origin:   server.url_origin
				header_count: server.header_count
				header_names: server.header_names
				enabled:      state.is_enabled(plugin.name, plugin_component_kind_mcp, server.name)
			}
		}
		plugins << PluginCatalogEntry{
			name:             plugin.name
			version:          plugin.version
			description:      plugin.description
			skills:           skills
			mcp_servers:      mcp_servers
			diagnostics:      plugin.diagnostics
			veasel_extension: plugin.veasel_extension
			origin:           plugin.origin
		}
	}
	return PluginCatalog{
		plugins:     plugins
		diagnostics: catalog.diagnostics
	}
}
