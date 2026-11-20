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
		'{"id":"pending-one","version":"1.0.0","license":"MIT","trust":"community","review":"pending-initial-review","installable":false,"opt_in_required":true,"source":{"type":"github","repo":"example/pending","ref":"v1","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"permissions":{"shell":"false","network":"false","mcp":"[]","hooks":"[]","dangerous_permissions":"[]"}},\n' +
		'{"id":"lying-one","version":"1.0.0","license":"MIT","trust":"community","review":"pending-initial-review","installable":true,"opt_in_required":true,"source":{"type":"github","repo":"example/lying","ref":"v1","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"permissions":{"shell":"true","network":"false","mcp":"[]","hooks":"[]","dangerous_permissions":"[]"}},\n' +
		'{"id":"revoked-one","version":"1.0.0","license":"MIT","trust":"verified","review":"revoked","installable":true,"opt_in_required":false,"source":{"type":"github","repo":"example/revoked","ref":"v1","sha":"cccccccccccccccccccccccccccccccccccccccc"},"permissions":{"shell":"false","network":"false","mcp":"[]","hooks":"[]","dangerous_permissions":"[]"}}\n]}'
	catalog_path := os.join_path(base, 'veasel-catalog.json')
	os.write_file(catalog_path, catalog) or { panic(err) }
	plugin_dir := os.join_path(base, 'installed')
	os.mkdir_all(plugin_dir) or { panic(err) }
	registry := os.join_path(base, 'plugin-links.json')
	return base, catalog_path, plugin_dir
}

fn test_library_pending_revoked_and_lying_entries_fail_closed() {
	base, catalog_path, plugin_dir := write_library_fixture()
	defer { os.rmdir_all(base) or {} }
	registry := os.join_path(base, 'plugin-links.json')
	catalog := load_library_catalog(catalog_path) or { panic(err) }
	assert catalog.plugins.len == 4
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

fn test_bundled_offline_catalog_loads_and_stays_pending_review() {
	// The catalog physically shipped in this repository (bundled/) is the
	// offline fallback: it loads with no network, lists only bundled
	// content, and never claims installability before owner review (#10).
	path := bundled_library_catalog_path_from([os.getwd()])
	assert path.len > 0, 'bundled catalog must exist in the repository layout'
	catalog := load_library_catalog(path) or { panic(err) }
	assert catalog.plugins.len == 1
	entry := catalog.entry('veasel-essentials') or { panic('bundled entry missing') }
	assert entry.trust == 'first-party'
	installable, reason := library_entry_installable(entry)
	assert !installable
	assert reason.contains('not approved'), reason
	package := library_resolve_package(os.dir(path), entry, LibraryInstallOptions{}) or {
		panic(err)
	}
	plugin := load_agent_plugin(package) or { panic(err) }
	assert plugin.manifest.name == 'veasel-essentials'
	assert plugin.skills.len == 1
	assert plugin.skills[0].name == 'output-handshake'
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
