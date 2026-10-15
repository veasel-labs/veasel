module main

fn test_headless_plugins_parses_components_commands() {
	listed := parse_headless_plugins_args(['components', 'list', '--json']) or { panic(err) }
	assert listed.action == .components_list
	assert listed.json

	enabled := parse_headless_plugins_args([
		'components',
		'enable',
		'demo',
		'skill',
		'helper',
	]) or { panic(err) }
	assert enabled.action == .components_enable
	assert enabled.plugin == 'demo'
	assert enabled.kind == plugin_component_kind_skill
	assert enabled.name == 'helper'

	disabled := parse_headless_plugins_args([
		'components',
		'disable',
		'demo',
		'mcp',
		'local',
	]) or { panic(err) }
	assert disabled.action == .components_disable
	assert disabled.kind == plugin_component_kind_mcp
	assert disabled.name == 'local'

	if _ := parse_headless_plugins_args(['components', 'enable', 'demo', 'tool', 'x']) {
		assert false
	}
	if _ := parse_headless_plugins_args(['components', 'list', 'extra']) {
		assert false
	}
}

fn test_headless_plugins_parses_links_commands() {
	listed := parse_headless_plugins_args(['links', 'list', '--json']) or { panic(err) }
	assert listed.action == .links_list
	assert listed.json

	added := parse_headless_plugins_args([
		'links',
		'add',
		'/tmp/external-plugin',
	]) or { panic(err) }
	assert added.action == .links_add
	assert added.path == '/tmp/external-plugin'

	removed := parse_headless_plugins_args(['links', 'remove', 'demo']) or { panic(err) }
	assert removed.action == .links_remove
	assert removed.name == 'demo'

	if _ := parse_headless_plugins_args(['links', 'add']) {
		assert false
	}
}
