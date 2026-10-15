module main

import json2
import os

// PluginLink is one operator-managed symlink under the plugin directory that
// points at an external Agent Plugin package. PLUGIN_DATA remains keyed by
// plugin name and is preserved across relinks. Summary fields come from the
// validated package manifest/components so install UX can preview without a
// separate catalog round-trip; they never expose secrets or nested paths.
pub struct PluginLink {
pub:
	name             string
	path             string
	version          string
	description      string
	display_name     string
	skill_count      int
	mcp_server_count int
}

pub struct PluginLinkCatalog {
pub:
	links       []PluginLink
	diagnostics []PluginDiagnostic
}

pub struct PluginLinkRemoval {
pub:
	removed string
}

struct PluginLinkInput {
pub:
	path string
}

// resolve_plugin_package_directory resolves an immediate child of the plugin
// directory. Ordinary directories must stay inside the plugin root. A single
// symlink child may point at an external package directory so operators can
// link local checkouts without copying them; nested package paths still use
// plugin_path containment against that package root.
fn resolve_plugin_package_directory(plugin_directory string, entry string) !string {
	if entry.len == 0 || entry.contains('/') || entry.contains('\\') || entry.contains('\x00')
		|| entry in ['.', '..'] {
		return error('invalid plugin package entry')
	}
	root := canonical_plugin_root(plugin_directory)!
	joined := os.join_path(root, entry)
	if !os.exists(joined) {
		return error('plugin package does not exist')
	}
	if os.is_link(joined) {
		target := os.real_path(joined)
		if !os.is_abs_path(target) || !os.is_dir(target) || os.is_link(target) {
			return error('plugin link must resolve to a directory')
		}
		return target
	}
	return plugin_path(root, entry)!
}

fn list_plugin_links(plugin_directory string) !PluginLinkCatalog {
	root := canonical_plugin_root(plugin_directory)!
	entries := os.ls(root) or { return error('unable to list the plugin directory') }
	mut links := []PluginLink{}
	mut diagnostics := []PluginDiagnostic{}
	for entry in entries.sorted() {
		joined := os.join_path(root, entry)
		if !os.is_link(joined) {
			continue
		}
		target := resolve_plugin_package_directory(root, entry) or {
			diagnostics << PluginDiagnostic{
				component: entry
				message:   'Skipping broken plugin link: ${err.msg()}'
			}
			continue
		}
		plugin := load_agent_plugin(target) or {
			diagnostics << PluginDiagnostic{
				component: entry
				message:   'Skipping invalid linked plugin package: ${err.msg()}'
			}
			continue
		}
		links << plugin_link_from_package(plugin, target)
	}
	return PluginLinkCatalog{
		links:       links
		diagnostics: diagnostics
	}
}

fn plugin_link_from_package(plugin AgentPlugin, package_path string) PluginLink {
	return PluginLink{
		name:             plugin.manifest.name
		path:             package_path
		version:          plugin.manifest.version
		description:      plugin.manifest.description
		display_name:     plugin.manifest.veasel_display_name
		skill_count:      plugin.skills.len
		mcp_server_count: plugin.mcp_servers.len
	}
}

fn add_plugin_link(plugin_directory string, package_path string) !PluginLink {
	root := canonical_plugin_root(plugin_directory)!
	absolute := package_path.trim_space()
	if absolute.len == 0 || !os.is_abs_path(absolute) {
		return error('plugin link path must be an absolute directory')
	}
	if os.is_link(absolute) {
		return error('plugin link path must not itself be a symbolic link')
	}
	if !os.is_dir(absolute) {
		return error('plugin link path must be an existing directory')
	}
	canonical_package := os.real_path(absolute)
	if path_is_within(root, canonical_package) {
		return error('plugin link path must be outside the plugin directory; place packages there directly instead')
	}
	plugin := load_agent_plugin(canonical_package)!
	if !is_valid_plugin_name(plugin.manifest.name) {
		return error('plugin package name is invalid')
	}
	link_path := os.join_path(root, plugin.manifest.name)
	if os.exists(link_path) {
		if !os.is_link(link_path) {
			return error('a non-link plugin entry named `${plugin.manifest.name}` already exists')
		}
		existing := os.real_path(link_path)
		if existing == canonical_package {
			return plugin_link_from_package(plugin, canonical_package)
		}
		return error('plugin link `${plugin.manifest.name}` already points elsewhere')
	}
	os.symlink(canonical_package, link_path) or {
		return error('unable to create plugin link: ${err.msg()}')
	}
	return plugin_link_from_package(plugin, canonical_package)
}

fn remove_plugin_link(plugin_directory string, name string) ! {
	if !is_valid_plugin_name(name) {
		return error('plugin name is invalid')
	}
	root := canonical_plugin_root(plugin_directory)!
	link_path := os.join_path(root, name)
	if !os.exists(link_path) {
		return error('plugin link not found')
	}
	if !os.is_link(link_path) {
		return error('refusing to remove a non-link plugin package; delete it outside Veasel')
	}
	os.rm(link_path) or { return error('unable to remove plugin link: ${err.msg()}') }
}

fn plugin_package_origin(plugin_directory string, entry string) string {
	joined := os.join_path(plugin_directory, entry)
	if os.is_link(joined) {
		return 'link'
	}
	return ''
}

fn decode_plugin_link_input(raw string) !PluginLinkInput {
	fields := json2.decode[map[string]json2.Any](raw) or {
		return error('Expected a path field')
	}
	path_value := fields['path'] or { return error('Expected a path field') }
	if path_value !is string {
		return error('Expected a path field')
	}
	return PluginLinkInput{
		path: path_value as string
	}
}
