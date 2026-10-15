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
