module main

import json2
import os
import uuid

const library_test_manifest = '{"' + plugin_schema_key + '":"' + plugin_manifest_schema +
	'","name":"essentials","version":"0.1.0","description":"Offline essentials."}'

fn write_library_fixture() (string, string, string) {
	base := os.join_path(os.temp_dir(), 'veasel-library-${uuid.new_v4().str()}')
	pkg := os.join_path(base, 'plugins', 'essentials')
	os.mkdir_all(os.join_path(pkg, 'skills', 'hello')) or { panic(err) }
	os.write_file(os.join_path(pkg, 'plugin.json'), library_test_manifest) or { panic(err) }
	os.write_file(os.join_path(pkg, 'skills', 'hello', 'SKILL.md'),
		'---\nname: hello\ndescription: Say hello.\n---\n\nHello body.') or { panic(err) }
	catalog := '{\n"name":"veasel","version":1,"plugins":[\n' +
		'{"id":"essentials","version":"0.1.0","license":"MIT","trust":"first-party","review":"approved","installable":true,"opt_in_required":false,"source":{"type":"relative","path":"plugins/essentials","ref":"main","sha":"0000000000000000000000000000000000000000"},"permissions":{"shell":"false","network":"false","mcp":"[]","hooks":"[]","dangerous_permissions":"[]"}},\n' +
		'{"id":"pending-one","version":"1.0.0","license":"MIT","trust":"community","review":"pending-initial-review","installable":false,"opt_in_required":true,"source":{"type":"github","repo":"example/pending","ref":"v1","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"permissions":{"shell":"false","network":"false","mcp":"[]","hooks":"[]","dangerous_permissions":"[]"},"provenance":{"submitted_by":"fixture","reviewed_by":null,"review":"pending-initial-review"}},\n' +
		'{"id":"lying-one","version":"1.0.0","license":"MIT","trust":"community","review":"pending-initial-review","installable":true,"opt_in_required":true,"source":{"type":"github","repo":"example/lying","ref":"v1","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"permissions":{"shell":"true","network":"false","mcp":"[]","hooks":"[]","dangerous_permissions":"[]"}},\n' +
		'{"id":"revoked-one","version":"1.0.0","license":"MIT","trust":"verified","review":"revoked","installable":true,"opt_in_required":false,"source":{"type":"github","repo":"example/revoked","ref":"v1","sha":"cccccccccccccccccccccccccccccccccccccccc"},"permissions":{"shell":"false","network":"false","mcp":"[]","hooks":"[]","dangerous_permissions":"[]"}},\n' +
		'{"id":"approved-external","version":"1.0.0","license":"MIT","trust":"verified","review":"approved","installable":true,"opt_in_required":false,"source":{"type":"github","repo":"example/approved","path":"plugins/approved","ref":"v1","sha":"dddddddddddddddddddddddddddddddddddddddd"},"permissions":{"shell":"false","network":"false","mcp":"[]","hooks":"[]","dangerous_permissions":"[]"},"provenance":{"submitted_by":"maintainer","reviewed_by":"reviewer","review":"approved","reviewed_at":"2026-11-28","reviewed_source_sha":"dddddddddddddddddddddddddddddddddddddddd","review_evidence":"https://github.com/example/registry/pull/20"}}\n]}'
	catalog_path := os.join_path(base, 'veasel-catalog.json')
	os.write_file(catalog_path, catalog) or { panic(err) }
	plugin_dir := os.join_path(base, 'installed')
	os.mkdir_all(plugin_dir) or { panic(err) }
	registry := os.join_path(base, 'plugin-links.json')
	return base, catalog_path, plugin_dir
}

fn write_library_git_cache_fixture() (string, string) {
	base := os.join_path(os.temp_dir(), 'veasel-library-cache-${uuid.new_v4().str()}')
	cache := os.join_path(base, 'cache')
	clone := os.join_path(cache, 'plugin-aaaaaaaaaaaa')
	os.mkdir_all(os.join_path(clone, '.git', 'hooks')) or { panic(err) }
	os.write_file(os.join_path(clone, '.git', 'config'), '[core]\nrepositoryformatversion = 0\n') or {
		panic(err)
	}
	return base, clone
}

fn test_library_pending_revoked_and_lying_entries_fail_closed() {
	base, catalog_path, plugin_dir := write_library_fixture()
	defer { os.rmdir_all(base) or {} }
	registry := os.join_path(base, 'plugin-links.json')
	catalog := load_library_catalog(catalog_path) or { panic(err) }
	assert catalog.plugins.len == 5
	pending := catalog.entry('pending-one') or { panic('pending entry missing') }
	assert pending.provenance.reviewed_by == ''
	for id in ['pending-one', 'lying-one', 'revoked-one'] {
		entry := catalog.entry(id) or { panic('missing catalog entry') }
		installable, reason := library_entry_installable(entry)
		assert !installable, '${id} must not be installable: ${reason}'
		_ := install_library_entry(plugin_dir, registry, base, entry, LibraryInstallOptions{}) or {
			assert err.msg().len > 0
			continue
		}
		panic('${id} install must fail closed')
	}
	links := list_plugin_links(plugin_dir, registry) or { panic(err) }
	assert links.links.len == 0
}

fn test_library_catalog_decodes_and_checks_external_review_provenance() {
	base, catalog_path, plugin_dir := write_library_fixture()
	defer { os.rmdir_all(base) or {} }
	catalog := load_library_catalog(catalog_path) or { panic(err) }
	entry := catalog.entry('approved-external') or { panic('approved entry missing') }
	assert entry.provenance.submitted_by == 'maintainer'
	assert entry.provenance.reviewed_by == 'reviewer'
	assert entry.provenance.reviewed_source_sha == entry.source.sha
	installable, reason := library_entry_installable(entry)
	assert installable, reason
	registry := os.join_path(base, 'plugin-links.json')
	view := library_catalog_view(plugin_dir, registry, catalog_path) or { panic(err) }
	mut approved_provenance_valid := false
	mut pending_provenance_valid := true
	for row in view.entries {
		if row.id == 'approved-external' {
			approved_provenance_valid = row.review_provenance_valid
		}
		if row.id == 'pending-one' {
			pending_provenance_valid = row.review_provenance_valid
		}
	}
	assert approved_provenance_valid
	assert !pending_provenance_valid
}

fn test_library_unknown_trust_and_unbound_external_approval_fail_closed() {
	sha := 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	unknown := LibraryEntry{
		id:          'external-one'
		trust:       'mystery'
		review:      'approved'
		installable: true
		source:      LibrarySource{
			typ:  'github'
			path: 'plugins/external-one'
			sha:  sha
		}
	}
	unknown_installable, unknown_reason := library_entry_installable(unknown)
	assert !unknown_installable
	assert unknown_reason.contains('unknown trust tier')

	missing_provenance := LibraryEntry{
		id:          'external-one'
		trust:       'verified'
		review:      'approved'
		installable: true
		source:      LibrarySource{
			typ:  'github'
			path: 'plugins/external-one'
			sha:  sha
		}
	}
	missing_installable, missing_reason := library_entry_installable(missing_provenance)
	assert !missing_installable
	assert missing_reason.contains('review provenance')

	valid_provenance := LibraryEntry{
		id:          'external-one'
		trust:       'verified'
		review:      'approved'
		installable: true
		source:      LibrarySource{
			typ:  'github'
			path: 'plugins/external-one'
			sha:  sha
		}
		provenance:  LibraryProvenance{
			submitted_by:        'author'
			review:              'approved'
			reviewed_by:         'reviewer'
			reviewed_at:         '2026-11-28'
			reviewed_source_sha: sha
			review_evidence:     'https://github.com/veasel-labs/agent-toolkit/pull/20'
		}
	}
	valid_installable, valid_reason := library_entry_installable(valid_provenance)
	assert valid_installable, valid_reason

	unsubmitted_provenance := LibraryEntry{
		id:          'external-one'
		trust:       'verified'
		review:      'approved'
		installable: true
		source:      LibrarySource{
			typ:  'github'
			path: 'plugins/external-one'
			sha:  sha
		}
		provenance:  LibraryProvenance{
			review:              'approved'
			reviewed_by:         'reviewer'
			reviewed_at:         '2026-11-28'
			reviewed_source_sha: sha
			review_evidence:     'https://github.com/veasel-labs/agent-toolkit/pull/20'
		}
	}
	unsubmitted_installable, unsubmitted_reason := library_entry_installable(unsubmitted_provenance)
	assert !unsubmitted_installable
	assert unsubmitted_reason.contains('review provenance')

	mismatched_provenance := LibraryEntry{
		id:          'external-one'
		trust:       'verified'
		review:      'approved'
		installable: true
		source:      LibrarySource{
			typ:  'github'
			path: 'plugins/external-one'
			sha:  sha
		}
		provenance:  LibraryProvenance{
			review:              'approved'
			reviewed_by:         'reviewer'
			reviewed_at:         '2026-11-28'
			reviewed_source_sha: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
			review_evidence:     'https://github.com/veasel-labs/agent-toolkit/pull/20'
		}
	}
	mismatch_installable, mismatch_reason := library_entry_installable(mismatched_provenance)
	assert !mismatch_installable
	assert mismatch_reason.contains('review provenance')
}

fn test_library_install_review_remove_relative_entry() {
	base, catalog_path, plugin_dir := write_library_fixture()
	defer { os.rmdir_all(base) or {} }
	registry := os.join_path(base, 'plugin-links.json')
	catalog := load_library_catalog(catalog_path) or { panic(err) }
	entry := catalog.entry('essentials') or { panic('missing catalog entry') }
	installable, _ := library_entry_installable(entry)
	assert installable
	summary := library_permission_summary(entry)
	assert summary.contains('shell=false')
	link := install_library_entry(plugin_dir, registry, base, entry, LibraryInstallOptions{}) or {
		panic(err)
	}
	assert link.name == 'essentials'
	assert link.skill_count == 1
	discovered := discover_agent_plugins(plugin_dir) or { panic(err) }
	assert discovered.plugins.len == 1
	remove_library_entry(plugin_dir, registry, entry) or { panic(err) }
	after := discover_agent_plugins(plugin_dir) or { panic(err) }
	assert after.plugins.len == 0
}

fn test_library_community_requires_opt_in_and_dangerous_requires_ack() {
	base, _, plugin_dir := write_library_fixture()
	defer { os.rmdir_all(base) or {} }
	registry := os.join_path(base, 'plugin-links.json')
	mut entry := LibraryEntry{
		id:          'community-one'
		version:     '1.0.0'
		trust:       'community'
		review:      'approved'
		installable: true
		source:      LibrarySource{
			typ:  'relative'
			path: 'plugins/essentials'
		}
	}
	_ := install_library_entry(plugin_dir, registry, base, entry, LibraryInstallOptions{}) or {
		assert err.msg().contains('opt-in')
		entry = LibraryEntry{
			id:          'community-one'
			version:     '1.0.0'
			trust:       'community'
			review:      'approved'
			installable: true
			source:      LibrarySource{
				typ:  'relative'
				path: 'plugins/essentials'
			}
			permissions: {
				'dangerous_permissions': json2.Any('[shell-admin]')
			}
		}
		_ := install_library_entry(plugin_dir, registry, base, entry, LibraryInstallOptions{
			allow_community: true
		}) or {
			assert err.msg().contains('dangerous')
			link := install_library_entry(plugin_dir, registry, base, entry, LibraryInstallOptions{
				allow_community:  true
				accept_dangerous: true
			}) or { panic(err) }
			assert link.name == 'essentials'
			return
		}
		panic('dangerous permissions must require acknowledgement')
	}
	panic('community entry must require opt-in')
}

fn test_library_invalid_catalog_structures_rejected() {
	base := os.join_path(os.temp_dir(), 'veasel-library-bad-${uuid.new_v4().str()}')
	os.mkdir_all(base) or { panic(err) }
	defer { os.rmdir_all(base) or {} }
	for raw in ['{"plugins":[{"id":"Bad ID"}]}', '{"plugins":[{"id":"x"},{"id":"x"}]}',
		'{"plugins":[{"id":"x","source":{"type":"github","sha":"nothex"}}]}', 'not json'] {
		path := os.join_path(base, 'catalog.json')
		os.write_file(path, raw) or { panic(err) }
		_ := load_library_catalog(path) or { continue }
		panic('invalid catalog must be rejected: ${raw}')
	}
}

fn test_library_relative_source_rejects_symlink_escape() {
	$if windows {
		return
	}
	base, _, _ := write_library_fixture()
	defer { os.rmdir_all(base) or {} }
	outside := '${base}-outside'
	defer { os.rmdir_all(outside) or {} }
	os.mkdir_all(outside) or { panic(err) }
	link := os.join_path(base, 'plugins', 'escape')
	os.symlink(outside, link) or { panic(err) }
	entry := LibraryEntry{
		id:     'escape'
		trust:  'first-party'
		review: 'approved'
		source: LibrarySource{
			typ:  'relative'
			path: 'plugins/escape'
		}
	}
	if _ := library_resolve_package(base, entry, LibraryInstallOptions{}) {
		assert false, 'relative library source must not follow a symlink outside the catalog'
	}
}

fn test_library_package_path_rejects_symlinked_git_subdirectory_escape() {
	$if windows {
		return
	}
	base := os.join_path(os.temp_dir(), 'veasel-library-subdir-${uuid.new_v4().str()}')
	root := os.join_path(base, 'repo')
	outside := os.join_path(base, 'outside')
	os.mkdir_all(root) or { panic(err) }
	os.mkdir_all(outside) or { panic(err) }
	defer { os.rmdir_all(base) or {} }
	os.symlink(outside, os.join_path(root, 'plugin')) or { panic(err) }
	if _ := library_package_path_under_root(root, os.join_path(root, 'plugin')) {
		assert false, 'git-subdir package must not follow a symlink outside its cloned repository'
	}
}

fn test_library_cached_clone_rejects_symlinked_root_and_git_metadata() {
	$if windows {
		return
	}
	base := os.join_path(os.temp_dir(), 'veasel-library-cache-links-${uuid.new_v4().str()}')
	cache := os.join_path(base, 'cache')
	outside := os.join_path(base, 'outside')
	clone := os.join_path(cache, 'plugin-aaaaaaaaaaaa')
	os.mkdir_all(cache) or { panic(err) }
	os.mkdir_all(outside) or { panic(err) }
	defer { os.rmdir_all(base) or {} }
	os.symlink(outside, clone) or { panic(err) }
	if _ := library_validate_cached_clone(cache, clone) {
		assert false, 'library cache must reject a symlinked clone root'
	}
	os.rm(clone) or { panic(err) }
	_, normal_clone := write_library_git_cache_fixture()
	defer { os.rmdir_all(os.dir(os.dir(normal_clone))) or {} }
	os.symlink(outside, os.join_path(normal_clone, '.git', 'metadata-link')) or { panic(err) }
	if _ := library_validate_cached_clone(os.dir(normal_clone), normal_clone) {
		assert false, 'library cache must reject symlinks inside git metadata'
	}
}

fn test_library_cached_clone_rejects_git_filter_configuration() {
	base, clone := write_library_git_cache_fixture()
	defer { os.rmdir_all(base) or {} }
	os.write_file(os.join_path(clone, '.git', 'config'), '[filter "unsafe"]\nsmudge = touch outside\n') or {
		panic(err)
	}
	if _ := library_validate_cached_clone(os.dir(clone), clone) {
		assert false, 'library cache must reject Git filters before checkout'
	}
}

fn test_library_cached_clone_rejects_symlinked_git_directory() {
	$if windows {
		return
	}
	base, clone := write_library_git_cache_fixture()
	defer { os.rmdir_all(base) or {} }
	git_dir := os.join_path(clone, '.git')
	outside := os.join_path(base, 'outside-git')
	os.mkdir_all(outside) or { panic(err) }
	os.rmdir_all(git_dir) or { panic(err) }
	os.symlink(outside, git_dir) or { panic(err) }
	if _ := library_validate_cached_clone(os.dir(clone), clone) {
		assert false, 'library cache must reject a symlinked git metadata directory'
	}
}

fn test_library_git_metadata_walk_fails_closed_at_entry_limit() {
	root := os.join_path(os.temp_dir(), 'veasel-library-git-limit-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	os.write_file(os.join_path(root, 'one'), '1') or { panic(err) }
	os.write_file(os.join_path(root, 'two'), '2') or { panic(err) }
	if _ := library_git_metadata_has_symlink_with_limit(root, 1) {
		assert false, 'Git metadata walk must fail closed after its entry limit'
	}
}

fn test_library_git_runner_disables_hooks_and_returns_command_output() {
	hooks_path := run_library_git_command(os.temp_dir(), ['config', '--get', 'core.hooksPath']) or {
		panic(err)
	}
	assert hooks_path.trim_space() == '/dev/null'
}

fn test_bundled_offline_catalog_is_approved_installable_and_permission_scoped() {
	// The catalog physically shipped in this repository (bundled/) is the
	// offline fallback: it loads with no network, lists only bundled
	// content, and matches the owner's first-party exception recorded in #10.
	path := bundled_library_catalog_path_from([os.getwd()])
	assert path.len > 0, 'bundled catalog must exist in the repository layout'
	catalog := load_library_catalog(path) or { panic(err) }
	assert catalog.plugins.len == 1
	entry := catalog.entry('veasel-essentials') or { panic('bundled entry missing') }
	assert entry.trust == 'first-party'
	assert entry.review == 'approved'
	assert entry.installable
	assert !entry.opt_in_required
	installable, reason := library_entry_installable(entry)
	assert installable, reason
	assert library_permission_summary(entry) == 'shell=false network=false mcp=none hooks=none dangerous_permissions=none'
	package := library_resolve_package(os.dir(path), entry, LibraryInstallOptions{}) or {
		panic(err)
	}
	plugin := load_agent_plugin(package) or { panic(err) }
	assert plugin.manifest.name == 'veasel-essentials'
	assert plugin.skills.len == 1
	assert plugin.skills[0].name == 'output-handshake'
	base := os.join_path(os.temp_dir(), 'veasel-bundled-install-${uuid.new_v4().str()}')
	os.mkdir_all(base) or { panic(err) }
	defer { os.rmdir_all(base) or {} }
	plugin_dir := os.join_path(base, 'plugins')
	os.mkdir_all(plugin_dir) or { panic(err) }
	registry := os.join_path(base, 'plugin-links.json')
	link := install_library_entry(plugin_dir, registry, os.dir(path), entry, LibraryInstallOptions{}) or {
		panic(err)
	}
	assert link.name == 'veasel-essentials'
	assert link.skill_count == 1
	discovered := discover_agent_plugins(plugin_dir) or { panic(err) }
	assert discovered.plugins.len == 1
	remove_library_entry(plugin_dir, registry, entry) or { panic(err) }
	after := discover_agent_plugins(plugin_dir) or { panic(err) }
	assert after.plugins.len == 0
}

fn test_library_headless_parse_requires_opt_in_flags_scoped() {
	opts := parse_headless_plugins_args(['library', 'install', '--opt-in', '--accept-dangerous',
		'essentials']) or { panic(err) }
	assert opts.action == .library_install
	assert opts.allow_community
	assert opts.accept_dangerous
	assert opts.name == 'essentials'
	_ := parse_headless_plugins_args(['links', 'add', '--opt-in', '/tmp/x']) or {
		assert err.msg().contains('--opt-in')
		return
	}
	panic('--opt-in must be rejected outside library install')
}
