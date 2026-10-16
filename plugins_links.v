module main

import json2
import os

// PluginLink is one operator-managed symlink under the plugin directory that
// points at an external Agent Plugin package. PLUGIN_DATA remains keyed by
// plugin name and is preserved across relinks. Summary fields come from the
// validated package manifest/components so install UX can preview without a
// separate catalog round-trip; they never expose secrets or nested paths.
// Intended targets are also recorded in `$VEASEL_DATA_DIR/plugin-links.json`
// so a missing symlink can be restored from the durable registry on list/add.
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
	path    string
	replace bool
}

struct PersistedPluginLinks {
mut:
	links map[string]string
}

const max_plugin_link_registry_entries = 128

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

fn (store &Store) plugin_links_path() string {
	if store.path == ':memory:' {
		return ''
	}
	return os.join_path(os.dir(store.path), 'plugin-links.json')
}

fn load_persisted_plugin_links(registry_path string) PersistedPluginLinks {
	mut empty := PersistedPluginLinks{
		links: map[string]string{}
	}
	if registry_path.len == 0 || !os.is_file(registry_path) {
		return empty
	}
	raw := os.read_file(registry_path) or { return empty }
	loaded := json2.decode[PersistedPluginLinks](raw) or { return empty }
	mut links := map[string]string{}
	for name, path in loaded.links {
		if links.len >= max_plugin_link_registry_entries {
			break
		}
		if !is_valid_plugin_name(name) {
			continue
		}
		trimmed := path.trim_space()
		if trimmed.len == 0 || !os.is_abs_path(trimmed) || trimmed.contains('\x00') {
			continue
		}
		links[name] = trimmed
	}
	return PersistedPluginLinks{
		links: links
	}
}

fn save_persisted_plugin_links(registry_path string, registry PersistedPluginLinks) ! {
	if registry_path.len == 0 {
		return
	}
	parent := os.dir(registry_path)
	if parent.len > 0 {
		os.mkdir_all(parent) or { return error('unable to create plugin link registry directory') }
	}
	os.write_file(registry_path, json2.encode(registry)) or {
		return error('unable to write plugin link registry')
	}
}

fn remember_plugin_link(registry_path string, name string, package_path string) ! {
	if registry_path.len == 0 {
		return
	}
	mut registry := load_persisted_plugin_links(registry_path)
	if name !in registry.links && registry.links.len >= max_plugin_link_registry_entries {
		return error('plugin link registry is full')
	}
	registry.links[name] = package_path
	save_persisted_plugin_links(registry_path, registry)!
}

fn forget_plugin_link(registry_path string, name string) ! {
	if registry_path.len == 0 {
		return
	}
	mut registry := load_persisted_plugin_links(registry_path)
	if name !in registry.links {
		return
	}
	registry.links.delete(name)
	save_persisted_plugin_links(registry_path, registry)!
}

fn list_plugin_links(plugin_directory string, registry_path string) !PluginLinkCatalog {
	root := canonical_plugin_root(plugin_directory)!
	entries := os.ls(root) or { return error('unable to list the plugin directory') }
	mut links := []PluginLink{}
	mut diagnostics := []PluginDiagnostic{}
	mut seen := map[string]bool{}
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
		seen[plugin.manifest.name] = true
		remember_plugin_link(registry_path, plugin.manifest.name, target) or {}
	}
	registry := load_persisted_plugin_links(registry_path)
	for name, package_path in registry.links {
		if seen[name] {
			continue
		}
		restored := restore_plugin_link_from_registry(root, name, package_path) or {
			diagnostics << PluginDiagnostic{
				component: name
				message:   'Durable plugin link `${name}` could not be restored: ${err.msg()}'
			}
			continue
		}
		links << restored
		seen[name] = true
		diagnostics << PluginDiagnostic{
			component: name
			message:   'Restored plugin link `${name}` from durable registry'
		}
	}
	links.sort(a.name < b.name)
	return PluginLinkCatalog{
		links:       links
		diagnostics: diagnostics
	}
}

fn restore_plugin_link_from_registry(plugin_root string, name string, package_path string) !PluginLink {
	if !is_valid_plugin_name(name) {
		return error('plugin name is invalid')
	}
	absolute := package_path.trim_space()
	if absolute.len == 0 || !os.is_abs_path(absolute) {
		return error('registered path must be an absolute directory')
	}
	if os.is_link(absolute) || !os.is_dir(absolute) {
		return error('registered path must be an existing directory')
	}
	canonical_package := os.real_path(absolute)
	if path_is_within(plugin_root, canonical_package) {
		return error('registered path must stay outside the plugin directory')
	}
	plugin := load_agent_plugin(canonical_package)!
	if plugin.manifest.name != name {
		return error('registered package name does not match `${name}`')
	}
	link_path := os.join_path(plugin_root, name)
	if os.exists(link_path) {
		if os.is_link(link_path) {
			existing := os.real_path(link_path)
			if existing == canonical_package {
				return plugin_link_from_package(plugin, canonical_package)
			}
			return error('a conflicting plugin link already exists')
		}
		return error('a non-link plugin entry already exists')
	}
	os.symlink(canonical_package, link_path) or {
		return error('unable to recreate plugin link: ${err.msg()}')
	}
	return plugin_link_from_package(plugin, canonical_package)
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

fn add_plugin_link(plugin_directory string, registry_path string, package_path string, replace bool) !PluginLink {
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
			remember_plugin_link(registry_path, plugin.manifest.name, canonical_package)!
			return plugin_link_from_package(plugin, canonical_package)
		}
		if !replace {
			return error('plugin link `${plugin.manifest.name}` already points elsewhere')
		}
		remove_plugin_symlink(link_path) or {
			return error('unable to replace plugin link: ${err.msg()}')
		}
	}
	os.symlink(canonical_package, link_path) or {
		return error('unable to create plugin link: ${err.msg()}')
	}
	remember_plugin_link(registry_path, plugin.manifest.name, canonical_package)!
	return plugin_link_from_package(plugin, canonical_package)
}

// remove_plugin_symlink unlinks a package symlink/junction. On Windows, directory
// junctions reject os.rm with "Permission denied"; prefer os.rmdir there, then
// fall back to os.rm for file symlinks on other platforms.
fn remove_plugin_symlink(link_path string) ! {
	$if windows {
		os.rmdir(link_path) or {
			os.rm(link_path) or { return error(err.msg()) }
		}
		return
	}
	os.rm(link_path) or {
		os.rmdir(link_path) or { return error(err.msg()) }
	}
}

fn remove_plugin_link(plugin_directory string, registry_path string, name string) ! {
	if !is_valid_plugin_name(name) {
		return error('plugin name is invalid')
	}
	root := canonical_plugin_root(plugin_directory)!
	link_path := os.join_path(root, name)
	mut removed_link := false
	if os.exists(link_path) {
		if !os.is_link(link_path) {
			return error('refusing to remove a non-link plugin package; delete it outside Veasel')
		}
		remove_plugin_symlink(link_path) or {
			return error('unable to remove plugin link: ${err.msg()}')
		}
		removed_link = true
	}
	registry := load_persisted_plugin_links(registry_path)
	had_registry := name in registry.links
	forget_plugin_link(registry_path, name)!
	if !removed_link && !had_registry {
		return error('plugin link not found')
	}
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
	mut replace := false
	if replace_value := fields['replace'] {
		if replace_value is bool {
			replace = replace_value as bool
		} else {
			return error('Expected replace to be a boolean')
		}
	}
	return PluginLinkInput{
		path:    path_value as string
		replace: replace
	}
}
