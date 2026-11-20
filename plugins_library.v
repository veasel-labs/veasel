module main

import json2
import os

// Integrated plugin Library (#706): discovery/install/update/removal on top
// of the existing plugin loader (plugins_links.v). The catalog is the
// generated veasel-catalog.json from veasel-labs/agent-toolkit; this code
// never widens the catalog-declared permission surface and fails closed on
// pending/revoked/experimental entries even if a catalog claims otherwise.

pub struct LibrarySource {
pub:
	typ  string @[json: 'type']
	repo string
	path string
	ref  string
	sha  string
}

pub struct LibraryEntry {
pub:
	id              string
	version         string
	license         string
	trust           string
	review          string
	installable     bool
	opt_in_required bool
	source          LibrarySource
	permissions     map[string]json2.Any
}

pub struct LibraryCatalog {
pub:
	name    string
	version int
	plugins []LibraryEntry
}

pub struct LibraryInstallOptions {
pub:
	allow_community  bool
	accept_dangerous bool
	update           bool
	cache_directory  string
}

fn (catalog LibraryCatalog) entry(id string) ?LibraryEntry {
	for entry in catalog.plugins {
		if entry.id == id {
			return entry
		}
	}
	return none
}

fn is_hex_sha(value string) bool {
	if value.len != 40 {
		return false
	}
	for ch in value {
		if !((ch >= `0` && ch <= `9`) || (ch >= `a` && ch <= `f`) || (ch >= `A` && ch <= `F`)) {
			return false
		}
	}
	return true
}

fn load_library_catalog(catalog_path string) !LibraryCatalog {
	raw := os.read_file(catalog_path) or { return error('unable to read library catalog') }
	catalog := json2.decode[LibraryCatalog](raw) or {
		return error('library catalog is not valid JSON')
	}
	if catalog.plugins.len == 0 || catalog.plugins.len > 512 {
		return error('library catalog has an invalid plugin count')
	}
	mut seen := map[string]bool{}
	for entry in catalog.plugins {
		if !is_valid_plugin_name(entry.id) {
			return error('library catalog entry id `${entry.id}` is invalid')
		}
		if entry.id in seen {
			return error('library catalog has duplicate entry `${entry.id}`')
		}
		seen[entry.id] = true
		if entry.source.typ == 'github' && !is_hex_sha(entry.source.sha) {
			return error('library catalog entry `${entry.id}` must pin a full commit sha')
		}
		if entry.source.typ !in ['github', 'git-subdir', 'relative'] {
			return error('library catalog entry `${entry.id}` has an unknown source type')
		}
	}
	return catalog
}

// library_entry_installable is fail-closed: the catalog's own installable
// flag is necessary but never sufficient on its own.
fn library_entry_installable(entry LibraryEntry) (bool, string) {
	if entry.review == 'revoked' {
		return false, 'review revoked'
	}
	if entry.trust == 'experimental' {
		return false, 'experimental trust tier is not published'
	}
	if entry.review != 'approved' {
		return false, 'review is not approved (${entry.review})'
	}
	if !entry.installable {
		return false, 'catalog marks this entry not installable'
	}
	return true, ''
}

fn library_permission_text(entry LibraryEntry, key string) string {
	value := entry.permissions[key] or { return '' }
	return value.str().trim('"[] ')
}

fn library_has_dangerous_permissions(entry LibraryEntry) bool {
	text := library_permission_text(entry, 'dangerous_permissions')
	return text.len > 0
}

fn library_permission_summary(entry LibraryEntry) string {
	mut parts := []string{}
	for key in ['shell', 'network', 'mcp', 'hooks', 'dangerous_permissions'] {
		text := library_permission_text(entry, key)
		shown := if text.len == 0 { 'none' } else { text }
		parts << '${key}=${shown}'
	}
	return parts.join(' ')
}

fn library_resolve_package(catalog_directory string, entry LibraryEntry, options LibraryInstallOptions) !string {
	match entry.source.typ {
		'relative' {
			if entry.source.path.len == 0 || os.is_abs_path(entry.source.path) {
				return error('relative library source must be a relative path')
			}
			package := os.norm_path(os.join_path(catalog_directory, entry.source.path))
			root := os.norm_path(catalog_directory)
			if package != root && !package.starts_with(root + os.path_separator) {
				return error('relative library source escapes the catalog directory')
			}
			if !os.is_dir(package) {
				return error('library package directory does not exist')
			}
			return package
		}
		'github', 'git-subdir' {
			if entry.source.repo.len == 0 || entry.source.repo.contains('..')
				|| entry.source.repo.count('/') != 1 {
				return error('library github source must be owner/repo')
			}
			sha := entry.source.sha
			if sha.trim('0').len == 0 {
				return error('library github source must pin a non-zero commit sha')
			}
			cache_root := if options.cache_directory.len > 0 {
				options.cache_directory
			} else {
				os.join_path(os.cache_dir(), 'veasel', 'library')
			}
			ensure_directory(cache_root) or {
				return error('unable to create library cache directory')
			}
			clone_dir := os.join_path(cache_root, '${entry.id}-${sha[..12]}')
			if !os.is_dir(os.join_path(clone_dir, '.git')) {
				url := 'https://github.com/${entry.source.repo}.git'
				cloned := os.exec(['git', 'clone', '-q', '--no-checkout', url, clone_dir])
				if cloned.exit_code != 0 {
					return error('unable to clone library package ${entry.source.repo}')
				}
			}
			checked := os.exec(['git', '-C', clone_dir, 'checkout', '-q', sha])
			if checked.exit_code != 0 {
				return error('unable to checkout pinned commit for ${entry.id}')
			}
			head := os.exec(['git', '-C', clone_dir, 'rev-parse', 'HEAD'])
			if head.exit_code != 0 || head.output.trim_space() != sha {
				return error('resolved commit for ${entry.id} does not match the catalog pin')
			}
			package := if entry.source.path.len > 0 {
				os.join_path(clone_dir, entry.source.path)
			} else {
				clone_dir
			}
			if !os.is_dir(package) {
				return error('library package path does not exist at the pinned commit')
			}
			return package
		}
		else {
			return error('unsupported library source type')
		}
	}
}

fn install_library_entry(plugin_directory string, registry_path string, catalog_directory string, entry LibraryEntry, options LibraryInstallOptions) !PluginLink {
	installable, reason := library_entry_installable(entry)
	if !installable {
		return error('library entry `${entry.id}` is not installable: ${reason}')
	}
	if (entry.trust == 'community' || entry.opt_in_required) && !options.allow_community {
		return error('library entry `${entry.id}` is a community plugin and requires explicit opt-in')
	}
	if library_has_dangerous_permissions(entry) && !options.accept_dangerous {
		return error('library entry `${entry.id}` declares dangerous permissions and requires explicit acknowledgement')
	}
	package := library_resolve_package(catalog_directory, entry, options)!
	return add_plugin_link(plugin_directory, registry_path, package, options.update)
}

fn remove_library_entry(plugin_directory string, registry_path string, entry LibraryEntry) ! {
	// Removal targets the installed link by the package's manifest name,
	// which the loader recorded at install time.
	remove_plugin_link(plugin_directory, registry_path, entry.id)!
}

pub struct LibraryEntryView {
pub:
	id                  string
	version             string
	license             string
	trust               string
	review              string
	installable         bool
	installable_reason  string
	opt_in_required     bool
	permissions_summary string
	installed           bool
}

pub struct LibraryCatalogView {
pub:
	name    string
	entries []LibraryEntryView
}

struct LibraryInstallInput {
pub:
	allow_community  bool
	accept_dangerous bool
	update           bool
}

fn library_catalog_path() string {
	if path := os.getenv_opt('VEASEL_CATALOG_PATH') {
		return path
	}
	// Offline fallback (#706): the catalog physically bundled next to the
	// executable. It only ever lists content that ships with the binary.
	// (No working-directory base: that would leak a checkout's catalog
	// into unrelated projects. Development can set VEASEL_CATALOG_PATH.)
	return bundled_library_catalog_path_from([os.dir(os.real_path(os.executable()))])
}

fn bundled_library_catalog_path_from(bases []string) string {
	for base in bases {
		candidate := os.join_path(base, 'bundled', 'catalog.json')
		if os.is_file(candidate) {
			return candidate
		}
	}
	return ''
}

fn library_catalog_view(plugin_directory string, registry_path string, catalog_path string) !LibraryCatalogView {
	catalog := load_library_catalog(catalog_path)!
	links := list_plugin_links(plugin_directory, registry_path)!
	mut installed := map[string]bool{}
	for link in links.links {
		installed[link.name] = true
	}
	mut entries := []LibraryEntryView{cap: catalog.plugins.len}
	for entry in catalog.plugins {
		installable, reason := library_entry_installable(entry)
		entries << LibraryEntryView{
			id:                  entry.id
			version:             entry.version
			license:             entry.license
			trust:               entry.trust
			review:              entry.review
			installable:         installable
			installable_reason:  reason
			opt_in_required:     entry.opt_in_required || entry.trust == 'community'
			permissions_summary: library_permission_summary(entry)
			installed:           entry.id in installed
		}
	}
	return LibraryCatalogView{
		name:    catalog.name
		entries: entries
	}
}

fn decode_library_install_input(raw string) !LibraryInstallInput {
	if raw.trim_space().len == 0 {
		return LibraryInstallInput{}
	}
	return json2.decode[LibraryInstallInput](raw) or {
		return error('Expected allow_community, accept_dangerous, and update fields')
	}
}
