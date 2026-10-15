module main

fn test_execution_policy_mode_from_maps_autonomous_and_aliases() {
	assert execution_policy_mode_from('', false) == .ask
	assert execution_policy_mode_from('ask', false) == .ask
	assert execution_policy_mode_from('auto-edit', false) == .auto_edit
	assert execution_policy_mode_from('auto_edit', false) == .auto_edit
	assert execution_policy_mode_from('sandbox-auto', false) == .sandbox_auto
	assert execution_policy_mode_from('yolo', false) == .sandbox_auto
	assert execution_policy_mode_from('ask', true) == .sandbox_auto
	assert execution_policy_mode_from('unknown', false) == .ask
}

fn test_execution_policy_ask_denies_side_effects_when_non_interactive() {
	assert decide_execution_permission(.ask, 'read', false, true) == .allow
	assert decide_execution_permission(.ask, 'edit', false, true) == .deny
	assert decide_execution_permission(.ask, 'shell', false, true) == .deny
	assert decide_execution_permission(.ask, 'mcp', false, true) == .deny
	assert decide_execution_permission(.ask, 'edit', true, true) == .ask
	assert decide_execution_permission(.ask, 'shell', true, true) == .ask
	assert decide_execution_permission(.ask, 'mcp', true, true) == .ask
}

fn test_execution_policy_auto_edit_allows_edits_and_asks_shell() {
	assert decide_execution_permission(.auto_edit, 'edit', false, false) == .allow
	assert decide_execution_permission(.auto_edit, 'shell', true, true) == .ask
	assert decide_execution_permission(.auto_edit, 'shell', false, true) == .deny
	assert decide_execution_permission(.auto_edit, 'mcp', true, true) == .ask
}

fn test_execution_policy_sandbox_auto_requires_os_sandbox_for_shell() {
	assert decide_execution_permission(.sandbox_auto, 'edit', false, false) == .allow
	assert decide_execution_permission(.sandbox_auto, 'shell', false, true) == .allow
	assert decide_execution_permission(.sandbox_auto, 'shell', false, false) == .deny
	assert decide_execution_permission(.sandbox_auto, 'mcp', true, true) == .deny
	assert decide_execution_permission(.sandbox_auto, 'mcp', false, true) == .deny
}

fn test_execution_policy_turn_from_input_sets_interactive() {
	interactive := execution_policy_turn_from_input('auto-edit', false, false)
	assert interactive.mode == .auto_edit
	assert interactive.interactive
	non_interactive := execution_policy_turn_from_input('', true, true)
	assert non_interactive.mode == .sandbox_auto
	assert !non_interactive.interactive
}
