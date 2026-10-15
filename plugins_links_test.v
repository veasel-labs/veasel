module main

import os
import uuid

const plugin_link_test_manifest = '{"' + plugin_schema_key + '":"' + plugin_manifest_schema +
	'","name":"review-tools","extensions":[],"future":true}'

fn test_plugin_links_add_list_remove_and_catalog_origin() {
	plugin_dir := os.join_path(os.temp_dir(), 'veasel-plugin-links-dir-${uuid.new_v4().str()}')
	package := os.join_path(os.temp_dir(), 'veasel-plugin-links-pkg-${uuid.new_v4().str()}')
	os.mkdir_all(plugin_dir) or { panic(err) }
	os.mkdir_all(os.join_path(package, 'skills', 'review')) or { panic(err) }
	defer {
		os.rmdir_all(plugin_dir) or {}
		os.rmdir_all(package) or {}
	}
	os.write_file(os.join_path(package, 'plugin.json'), plugin_link_test_manifest) or { panic(err) }
	os.write_file(os.join_path(package, 'skills', 'review', 'SKILL.md'), '---\nname: review\ndescription: Review changes.\n---\n\nLinked body.') or {
		panic(err)
	}

	link := add_plugin_link(plugin_dir, package) or { panic(err) }
	assert link.name == 'review-tools'
	assert link.path == os.real_path(package)
	again := add_plugin_link(plugin_dir, package) or { panic(err) }
	assert again.path == link.path

	listed := list_plugin_links(plugin_dir) or { panic(err) }
	assert listed.links.len == 1
	assert listed.links[0].name == 'review-tools'
	assert listed.links[0].path == link.path

	catalog := discover_agent_plugins(plugin_dir) or { panic(err) }
	assert catalog.plugins.len == 1
	assert catalog.plugins[0].name == 'review-tools'
	assert catalog.plugins[0].origin == 'link'
	assert catalog.plugins[0].skills.len == 1
	root, skill := find_agent_skill(plugin_dir, 'review-tools', 'review') or { panic(err) }
	assert load_skill_instructions(root, skill) or { panic(err) }.contains('Linked body.')

	remove_plugin_link(plugin_dir, 'review-tools') or { panic(err) }
	empty := list_plugin_links(plugin_dir) or { panic(err) }
	assert empty.links.len == 0
	after := discover_agent_plugins(plugin_dir) or { panic(err) }
	assert after.plugins.len == 0
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
	_ := add_plugin_link(plugin_dir, os.join_path(plugin_dir, 'nested-pkg')) or {
		assert err.msg().contains('outside the plugin directory')
		remove_plugin_link(plugin_dir, 'nested-pkg') or {
			assert err.msg().contains('non-link')
			return
		}
		assert false, 'should refuse removing a real package directory'
		return
	}
	assert false, 'should refuse linking a package already inside the plugin directory'
}
