module main

import os
import net.urllib

const max_plugin_packages = 128
const max_session_skill_context_bytes = 64_000

pub struct PluginCatalog {
pub:
	plugins     []PluginCatalogEntry
	diagnostics []PluginDiagnostic
}

pub struct VeaselCodeExtension {
pub:
	display_name  string @[json: 'display_name']
	has_directory bool   @[json: 'has_directory']
}

pub struct PluginCatalogEntry {
pub:
	name             string
	version          string
	description      string
	skills           []PluginSkillSummary
	mcp_servers      []PluginMCPServerSummary
	diagnostics      []PluginDiagnostic
	veasel_extension VeaselCodeExtension @[json: 'veasel_extension'; omitempty]
	origin           string              @[omitempty]
}

pub struct PluginSkillSummary {
pub:
	name                     string
	description              string
	location                 string @[omitempty]
	allowed_tools_declared   bool
	allowed_tools            []string
	source                   string @[omitempty]
	scope                    string @[omitempty]
	enabled                  bool = true
	disable_model_invocation bool @[json: 'disable_model_invocation'; omitempty]
}

pub struct PluginMCPServerSummary {
pub:
	name         string
	transport    string
	command      string
	url_origin   string
	header_count int
	header_names []string
	enabled      bool = true
}

fn discover_agent_plugins(directory string) !PluginCatalog {
	root := canonical_plugin_root(directory)!
	entries := os.ls(root) or { return error('unable to list the plugin directory') }
	if entries.len > max_plugin_packages {
		return error('plugin directory exceeds the ${max_plugin_packages} package limit')
	}
	mut plugins := []PluginCatalogEntry{cap: entries.len}
	mut diagnostics := []PluginDiagnostic{}
	mut names := map[string]bool{}
	for entry in entries.sorted() {
		package_path := resolve_plugin_package_directory(root, entry) or {
			diagnostics << PluginDiagnostic{
				component: entry
				message:   'Skipping package outside the plugin directory'
			}
			continue
		}
		if !os.is_dir(package_path) {
			continue
		}
		plugin := load_agent_plugin(package_path) or {
			diagnostics << PluginDiagnostic{
				component: entry
				message:   'Skipping invalid plugin package: ${err.msg()}'
			}
			continue
		}
		if plugin.manifest.name in names {
			diagnostics << PluginDiagnostic{
				component: entry
				message:   'Skipping duplicate plugin name `${plugin.manifest.name}`'
			}
			continue
		}
		names[plugin.manifest.name] = true
		mut skills := []PluginSkillSummary{cap: plugin.skills.len}
		for skill in plugin.skills {
			skills << PluginSkillSummary{
				name:                     skill.name
				description:              skill.description
				location:                 skill.directory
				allowed_tools_declared:   skill.allowed_tools_declared
				allowed_tools:            agent_skill_allowed_tool_names(skill.allowed_tools)
				enabled:                  true
				disable_model_invocation: skill.disable_model_invocation
			}
		}
		mut mcp_servers := []PluginMCPServerSummary{cap: plugin.mcp_servers.len}
		for server in plugin.mcp_servers {
			header_names := plugin_mcp_header_names(server.headers)
			mcp_servers << PluginMCPServerSummary{
				name:         server.name
				transport:    server.transport
				command:      server.command
				url_origin:   plugin_mcp_url_origin(server.url)
				header_count: server.headers.len
				header_names: header_names
				enabled:      true
			}
		}
		mut extension := VeaselCodeExtension{}
		if plugin.manifest.veasel_display_name.len > 0 || plugin.veasel_has_directory {
			extension = VeaselCodeExtension{
				display_name:  plugin.manifest.veasel_display_name
				has_directory: plugin.veasel_has_directory
			}
		}
		origin := plugin_package_origin(root, entry)
		plugins << PluginCatalogEntry{
			name:             plugin.manifest.name
			version:          plugin.manifest.version
			description:      plugin.manifest.description
			skills:           skills
			mcp_servers:      mcp_servers
			diagnostics:      plugin.diagnostics
			veasel_extension: extension
			origin:           origin
		}
	}
	return PluginCatalog{
		plugins:     plugins
		diagnostics: diagnostics
	}
}

fn plugin_mcp_header_names(headers map[string]string) []string {
	return headers.keys().sorted()
}

fn plugin_mcp_url_origin(value string) string {
	if value.len == 0 {
		return ''
	}
	parsed := urllib.parse(value) or { return '' }
	if parsed.scheme.len == 0 || parsed.host.len == 0 {
		return ''
	}
	return '${parsed.scheme.to_lower()}://${parsed.host.to_lower()}'
}

fn find_agent_skill(directory string, plugin_name string, skill_name string) !(string, PluginSkill) {
	if !is_valid_plugin_name(plugin_name) || !is_valid_skill_name(skill_name) {
		return error('plugin or skill name is invalid')
	}
	root := canonical_plugin_root(directory)!
	entries := os.ls(root)!
	if entries.len > max_plugin_packages {
		return error('plugin directory exceeds the ${max_plugin_packages} package limit')
	}
	for entry in entries.sorted() {
		package_path := resolve_plugin_package_directory(root, entry) or { continue }
		if !os.is_dir(package_path) {
			continue
		}
		plugin := load_agent_plugin(package_path) or { continue }
		if plugin.manifest.name != plugin_name {
			continue
		}
		for skill in plugin.skills {
			if skill.name == skill_name {
				return plugin.root, skill
			}
		}
		return error('skill not found in plugin')
	}
	return error('plugin not found')
}

fn find_agent_mcp_server(directory string, plugin_name string, server_name string) !(string, PluginMCPServer) {
	if !is_valid_plugin_name(plugin_name) || server_name.trim_space().len == 0 || server_name.len > 256
		|| server_name.contains('\0') {
		return error('plugin or MCP server name is invalid')
	}
	root := canonical_plugin_root(directory)!
	entries := os.ls(root)!
	if entries.len > max_plugin_packages {
		return error('plugin directory exceeds the ${max_plugin_packages} package limit')
	}
	for entry in entries.sorted() {
		package_path := resolve_plugin_package_directory(root, entry) or { continue }
		if !os.is_dir(package_path) {
			continue
		}
		plugin := load_agent_plugin(package_path) or { continue }
		if plugin.manifest.name != plugin_name {
			continue
		}
		for server in plugin.mcp_servers {
			if server.name == server_name {
				if server.transport !in ['stdio', 'streamable-http'] {
					return error('Agent Plugin MCP transport is not supported')
				}
				return plugin.root, server
			}
		}
		return error('MCP server not found in plugin')
	}
	return error('plugin not found')
}

struct AgentToolPolicy {
mut:
	restricted    bool
	allowed_tools map[string]bool
}

struct SessionSkillContext {
	instructions string
	tool_policy  AgentToolPolicy
mut:
	resource_access []AgentSkillResourceAccess
}

struct AgentSkillResourceAccess {
	plugin_name string
	skill_name  string
	skill_root  string
}

fn (policy AgentToolPolicy) allows(tool_name string) bool {
	return !policy.restricted || policy.allowed_tools[tool_name]
}

fn agent_skill_allowed_tool_names(value string) []string {
	mut names := []string{}
	mut seen := map[string]bool{}
	for token in value.split_any('\t\r\n ') {
		if token.len > 0 && !seen[token] {
			names << token
			seen[token] = true
		}
	}
	return names.sorted()
}

fn agent_tool_policy_for_skills(skills []PluginSkill) AgentToolPolicy {
	mut policy := AgentToolPolicy{
		allowed_tools: map[string]bool{}
	}
	for skill in skills {
		if !skill.allowed_tools_declared {
			continue
		}
		policy.restricted = true
		for name in agent_skill_allowed_tool_names(skill.allowed_tools) {
			policy.allowed_tools[name] = true
		}
	}
	return policy
}

fn load_session_skill_context(directory string, skills []SessionPluginSkill) !SessionSkillContext {
	return load_session_skill_context_for_project(directory, os.getwd(), skills)
}
