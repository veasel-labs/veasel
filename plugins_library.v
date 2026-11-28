module main

import json2
import os
import time

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

// Registry review evidence is retained internally so approved external
// entries can be checked against the immutable source they claim to review.
// The free-form values are deliberately omitted from the public view.
pub struct LibraryProvenance {
pub:
	submitted_by        string
	reviewed_by         string
	review              string
	reviewed_at         string
	reviewed_source_sha string
	review_evidence     string
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
	provenance      LibraryProvenance
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
		if entry.source.typ in ['github', 'git-subdir'] && !is_hex_sha(entry.source.sha) {
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
	if entry.trust !in ['first-party', 'verified', 'community'] {
		return false, 'unknown trust tier is not installable'
	}
	if entry.review != 'approved' {
		return false, 'review is not approved (${entry.review})'
	}
	if entry.source.typ in ['github', 'git-subdir'] && !library_review_provenance_valid(entry) {
		return false, 'approved external source is missing valid review provenance'
	}
	if !entry.installable {
		return false, 'catalog marks this entry not installable'
	}
	return true, ''
}

fn library_review_provenance_valid(entry LibraryEntry) bool {
	if entry.source.typ !in ['github', 'git-subdir'] {
		return true
	}
	if !is_hex_sha(entry.source.sha) || entry.provenance.reviewed_source_sha != entry.source.sha {
		return false
	}
	if entry.provenance.submitted_by.trim_space() in ['', 'null'] {
		return false
	}
	if entry.provenance.review != 'approved' || entry.provenance.reviewed_by.trim_space() in ['',
		'null'] {
		return false
	}
	date := entry.provenance.reviewed_at
	if date.len != 10 || date[4] != `-` || date[7] != `-` {
		return false
	}
	for i, ch in date {
		if i != 4 && i != 7 && (ch < `0` || ch > `9`) {
			return false
		}
	}
	return library_is_review_evidence_url(entry.provenance.review_evidence)
}

fn library_is_review_evidence_url(value string) bool {
	if !value.starts_with('https://github.com/') {
		return false
	}
	for ch in value {
		if ch <= ` ` {
			return false
		}
	}
	path := value.all_after('https://github.com/').split('/')
	if path.len != 4 || path[0].len == 0 || path[1].len == 0 || path[2] !in ['pull', 'issues'] {
		return false
	}
	issue := path[3].all_before('#')
	if issue.len == 0 {
		return false
	}
	for ch in issue {
		if ch < `0` || ch > `9` {
			return false
		}
	}
	if path[3].contains('#') {
		fragment := path[3].all_after('#')
		if !fragment.starts_with('issuecomment-') || fragment.len == 'issuecomment-'.len {
			return false
		}
		for ch in fragment.all_after('issuecomment-') {
			if ch < `0` || ch > `9` {
				return false
			}
		}
	}
	return true
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

fn library_package_path_under_root(root string, package string) !string {
	if !os.is_dir(root) || !os.is_dir(package) {
		return error('library package directory does not exist')
	}
	canonical_root := os.real_path(root)
	canonical_package := os.real_path(package)
	if canonical_root.len == 0 || canonical_package.len == 0
		|| !path_is_within(canonical_root, canonical_package) {
		return error('library package path escapes its source directory')
	}
	return canonical_package
}

const library_git_timeout = 120 * time.second
const library_git_output_limit = 4096
const max_library_git_metadata_entries = 100_000

fn library_git_metadata_has_symlink(root string) !bool {
	return library_git_metadata_has_symlink_with_limit(root, max_library_git_metadata_entries)
}

fn library_git_metadata_has_symlink_with_limit(root string, max_entries int) !bool {
	mut pending := [root]
	mut seen := 0
	for pending.len > 0 {
		current := pending.pop()
		children := os.ls(current) or {
			return error('unable to inspect library Git metadata')
		}
		seen += children.len
		if seen > max_entries {
			return error('library Git metadata exceeds the safety limit')
		}
		for child in children {
			path := os.join_path(current, child)
			if os.is_link(path) {
				return true
			}
			if os.is_dir(path) {
				pending << path
			}
		}
	}
	return false
}

fn library_validate_cached_clone(cache_root string, clone_dir string) !string {
	if os.is_link(clone_dir) {
		return error('library clone cache entry must not be a symlink')
	}
	canonical_clone := library_package_path_under_root(cache_root, clone_dir) or {
		return error('library clone cache entry escapes the cache directory')
	}
	git_dir := os.join_path(canonical_clone, '.git')
	if os.is_link(git_dir) || os.is_file(git_dir) || !os.is_dir(git_dir)
		|| !path_is_within(canonical_clone, git_dir) {
		return error('library clone metadata must be an in-cache directory')
	}
	if library_git_metadata_has_symlink(git_dir) or {
		return error('unable to validate library clone metadata')
	} {
		return error('library clone metadata must not contain symlinks')
	}
	config := os.join_path(git_dir, 'config')
	if os.is_link(config) || !os.is_file(config) || !path_is_within(git_dir, config) {
		return error('library clone configuration must be an in-cache file')
	}
	workspace_git_refuse_command_config(canonical_clone) or {
		return error('library clone has unsafe Git filters or includes')
	}
	return canonical_clone
}

fn run_library_git_command(checkout string, args []string) !string {
	git := os.find_abs_path_of_executable('git') or {
		return error('git executable is not available')
	}
	mut full_args := []string{}
	for setting in workspace_git_hardened_config() {
		full_args << '-c'
		full_args << setting
	}
	full_args << args
	mut process := os.new_process(git)
	process.set_args(full_args)
	process.set_work_folder(checkout)
	process.set_environment(workspace_git_untrusted_env())
	process.set_redirect_stdio()
	process.run()
	started := time.now()
	mut stdout := []u8{}
	for process.is_alive() || process.is_pending(.stdout) || process.is_pending(.stderr) {
		if time.since(started) > library_git_timeout {
			process.signal_kill()
			process.wait()
			process.close()
			return error('library Git operation timed out')
		}
		mut read_output := false
		if process.is_pending(.stdout) {
			chunk := process.stdout_read()
			if stdout.len + chunk.len > library_git_output_limit {
				process.signal_kill()
				process.wait()
				process.close()
				return error('library Git command output exceeded its limit')
			}
			stdout << chunk.bytes()
			read_output = true
		}
		if process.is_pending(.stderr) {
			_ = process.stderr_read()
			read_output = true
		}
		if !read_output {
			time.sleep(5 * time.millisecond)
		}
	}
	process.wait()
	code := process.code
	process.close()
	if code != 0 {
		return error('library Git operation failed')
	}
	return stdout.bytestr()
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
			return library_package_path_under_root(root, package)
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
			if os.is_link(clone_dir) {
				return error('library clone cache entry must not be a symlink')
			}
			if os.exists(clone_dir) {
				_ = library_validate_cached_clone(cache_root, clone_dir) or {
					return error('library clone cache entry is unsafe')
				}
			} else {
				url := 'https://github.com/${entry.source.repo}.git'
				run_library_git_command(cache_root, ['clone', '-q', '--no-checkout', url, clone_dir]) or { return error('unable to clone library package ${entry.source.repo}') }
				_ = library_validate_cached_clone(cache_root, clone_dir) or {
					return error('new library clone failed cache safety checks')
				}
			}
			run_library_git_command(cache_root, ['-C', clone_dir, 'checkout', '-q', sha]) or {
				return error('unable to checkout pinned commit for ${entry.id}')
			}
			head := run_library_git_command(cache_root, ['-C', clone_dir, 'rev-parse', 'HEAD']) or {
				return error('unable to verify pinned commit for ${entry.id}')
			}
			if head.trim_space() != sha {
				return error('resolved commit for ${entry.id} does not match the catalog pin')
			}
			package := if entry.source.path.len > 0 {
				os.join_path(clone_dir, entry.source.path)
			} else {
				clone_dir
			}
			return library_package_path_under_root(clone_dir, package)
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
	id                      string
	version                 string
	license                 string
	trust                   string
	review                  string
	installable             bool
	installable_reason      string
	opt_in_required         bool
	permissions_summary     string
	installed               bool
	review_provenance_valid bool
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
			id:                      entry.id
			version:                 entry.version
			license:                 entry.license
			trust:                   entry.trust
			review:                  entry.review
			installable:             installable
			installable_reason:      reason
			opt_in_required:         entry.opt_in_required || entry.trust == 'community'
			permissions_summary:     library_permission_summary(entry)
			installed:               entry.id in installed
			review_provenance_valid: library_review_provenance_valid(entry)
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
