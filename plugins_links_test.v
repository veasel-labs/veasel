module main

import os
import uuid

const plugin_link_test_manifest = '{"' + plugin_schema_key + '":"' + plugin_manifest_schema +
	'","name":"review-tools","version":"1.2.3","description":"Review helpers.","extensions":{"com.veasel.code":{"display_name":"Review Tools"}},"future":true}'

fn test_plugin_links_add_list_remove_and_catalog_origin() {
	plugin_dir := os.join_path(os.temp_dir(), 'veasel-plugin-links-dir-${uuid.new_v4().str()}')
	package := os.join_path(os.temp_dir(), 'veasel-plugin-links-pkg-${uuid.new_v4().str()}')
	registry := os.join_path(os.temp_dir(), 'veasel-plugin-links-registry-${uuid.new_v4().str()}.json')
	os.mkdir_all(plugin_dir) or { panic(err) }
	os.mkdir_all(os.join_path(package, 'skills', 'review')) or { panic(err) }
	defer {
		os.rmdir_all(plugin_dir) or {}
		os.rmdir_all(package) or {}
		os.rm(registry) or {}
	}
	os.write_file(os.join_path(package, 'plugin.json'), plugin_link_test_manifest) or { panic(err) }
	os.write_file(os.join_path(package, 'skills', 'review', 'SKILL.md'), '---\nname: review\ndescription: Review changes.\n---\n\nLinked body.') or {
		panic(err)
	}

	link := add_plugin_link(plugin_dir, registry, package, false) or { panic(err) }
	assert link.name == 'review-tools'
	assert link.path == os.real_path(package)
	assert link.version == '1.2.3'
	assert link.description == 'Review helpers.'
	assert link.display_name == 'Review Tools'
	assert link.skill_count == 1
	assert link.mcp_server_count == 0
	again := add_plugin_link(plugin_dir, registry, package, false) or { panic(err) }
	assert again.path == link.path
	assert again.version == '1.2.3'
	assert again.skill_count == 1
	persisted := load_persisted_plugin_links(registry)
	assert persisted.links['review-tools'] == os.real_path(package)

	listed := list_plugin_links(plugin_dir, registry) or { panic(err) }
	assert listed.links.len == 1
	assert listed.links[0].name == 'review-tools'
	assert listed.links[0].path == link.path
	assert listed.links[0].version == '1.2.3'
	assert listed.links[0].description == 'Review helpers.'
	assert listed.links[0].display_name == 'Review Tools'
	assert listed.links[0].skill_count == 1
	assert listed.links[0].mcp_server_count == 0

	catalog := discover_agent_plugins(plugin_dir) or { panic(err) }
	assert catalog.plugins.len == 1
	assert catalog.plugins[0].name == 'review-tools'
	assert catalog.plugins[0].origin == 'link'
	assert catalog.plugins[0].skills.len == 1
	root, skill := find_agent_skill(plugin_dir, 'review-tools', 'review') or { panic(err) }
	assert load_skill_instructions(root, skill) or { panic(err) }.contains('Linked body.')

	remove_plugin_link(plugin_dir, registry, 'review-tools') or { panic(err) }
	empty := list_plugin_links(plugin_dir, registry) or { panic(err) }
	assert empty.links.len == 0
	after := discover_agent_plugins(plugin_dir) or { panic(err) }
	assert after.plugins.len == 0
	assert load_persisted_plugin_links(registry).links.len == 0
}

fn test_plugin_links_refuse_inside_directory_and_non_link_removal() {
	plugin_dir := os.join_path(os.temp_dir(), 'veasel-plugin-links-refuse-${uuid.new_v4().str()}')
	os.mkdir_all(os.join_path(plugin_dir, 'nested-pkg', 'skills', 'review')) or { panic(err) }
	defer {
		os.rmdir_all(plugin_dir) or {}
	}
	os.write_file(os.join_path(plugin_dir, 'nested-pkg', 'plugin.json'), plugin_link_test_manifest) or {
		panic(err)
	}
	_ := add_plugin_link(plugin_dir, '', os.join_path(plugin_dir, 'nested-pkg'), false) or {
		assert err.msg().contains('outside the plugin directory')
		remove_plugin_link(plugin_dir, '', 'nested-pkg') or {
			assert err.msg().contains('non-link')
			return
		}
		assert false, 'should refuse removing a real package directory'
		return
	}
	assert false, 'should refuse linking a package already inside the plugin directory'
}

fn test_plugin_links_replace_and_restore_from_durable_registry() {
	plugin_dir := os.join_path(os.temp_dir(), 'veasel-plugin-links-replace-${uuid.new_v4().str()}')
	first := os.join_path(os.temp_dir(), 'veasel-plugin-links-first-${uuid.new_v4().str()}')
	second := os.join_path(os.temp_dir(), 'veasel-plugin-links-second-${uuid.new_v4().str()}')
	registry := os.join_path(os.temp_dir(), 'veasel-plugin-links-reg-${uuid.new_v4().str()}.json')
	os.mkdir_all(plugin_dir) or { panic(err) }
	os.mkdir_all(os.join_path(first, 'skills', 'review')) or { panic(err) }
	os.mkdir_all(os.join_path(second, 'skills', 'review')) or { panic(err) }
	defer {
		os.rmdir_all(plugin_dir) or {}
		os.rmdir_all(first) or {}
		os.rmdir_all(second) or {}
		os.rm(registry) or {}
	}
	os.write_file(os.join_path(first, 'plugin.json'), plugin_link_test_manifest) or { panic(err) }
	os.write_file(os.join_path(first, 'skills', 'review', 'SKILL.md'), '---\nname: review\ndescription: First package.\n---\n\nFirst body.') or {
		panic(err)
	}
	os.write_file(os.join_path(second, 'plugin.json'), plugin_link_test_manifest) or { panic(err) }
	os.write_file(os.join_path(second, 'skills', 'review', 'SKILL.md'), '---\nname: review\ndescription: Second package.\n---\n\nSecond body.') or {
		panic(err)
	}

	_ := add_plugin_link(plugin_dir, registry, first, false) or { panic(err) }
	_ := add_plugin_link(plugin_dir, registry, second, false) or {
		assert err.msg().contains('already points elsewhere')
		replaced := add_plugin_link(plugin_dir, registry, second, true) or { panic(err) }
		assert replaced.path == os.real_path(second)
		assert load_persisted_plugin_links(registry).links['review-tools'] == os.real_path(second)

		os.rm(os.join_path(plugin_dir, 'review-tools')) or { panic(err) }
		assert !os.exists(os.join_path(plugin_dir, 'review-tools'))
		restored := list_plugin_links(plugin_dir, registry) or { panic(err) }
		assert restored.links.len == 1
		assert restored.links[0].path == os.real_path(second)
		assert os.is_link(os.join_path(plugin_dir, 'review-tools'))
		assert restored.diagnostics.any(it.message.contains('Restored plugin link'))
		root, skill := find_agent_skill(plugin_dir, 'review-tools', 'review') or { panic(err) }
		assert load_skill_instructions(root, skill) or { panic(err) }.contains('Second body.')
		return
	}
	assert false, 'should refuse replacing without replace=true'
}
