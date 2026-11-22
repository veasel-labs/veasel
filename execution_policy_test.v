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

fn test_workspace_guidance_routes_repository_instructions_to_workspace_tools() {
	guidance := workspace_tool_instructions()
	assert guidance.contains('workspace_list_files')
	assert guidance.contains('workspace_read_file')
	assert guidance.contains('workspace_search')
	assert guidance.contains('workspace_propose_file_edit')
	assert guidance.contains('workspace_propose_file_content')
	assert execution_tool_class('workspace_propose_file_edit') == 'edit'
	assert execution_tool_class('workspace_propose_file_content') == 'edit'
	assert guidance.contains('using path, old_text, and new_text')
	assert guidance.contains('not Agent Skill resources')
	assert guidance.contains('continue the task with the available workspace tools')
	assert guidance.contains('do not stop solely because of that skill error')
	assert guidance.contains('Do not stop after summarizing files')
	assert guidance.contains('Proposals remain pending until the user approves them in the TUI')
}

fn test_installed_cli_guidance_matches_the_native_tool_plane() {
	guidance := installed_cli_tool_instructions('ask')
	assert guidance.contains('installed provider CLI and its native tools')
	assert guidance.contains('every native tool request requires an explicit Veasel approval')
	assert guidance.contains("not covered by Veasel's separate shell sandbox")
	assert !guidance.contains('workspace_propose_file_edit')
	assert !guidance.contains('workspace_propose_shell_command')

	change := installed_cli_code_change_instruction(true)
	assert change.contains('native file-inspection tool')
	assert change.contains('native edit tool')
	assert change.contains('Do not claim a change or verification')
	assert !change.contains('workspace_propose_file_edit')
	assert installed_cli_code_change_instruction(false) == ''
	assert installed_cli_tool_instructions('plan').contains('read-only')
	assert installed_cli_tool_instructions('accept-edits').contains('selected accept-edits')
}

fn test_agent_system_message_uses_the_selected_provider_tool_contract() {
	policy := ExecutionPolicyTurn{ mode: .ask, interactive: true }
	cli := agent_system_message_for_provider('claude-code', 'ask', policy, true)
	assert cli.contains('installed provider CLI and its native tools')
	assert cli.contains('native edit tool')
	assert !cli.contains('workspace_propose_file_edit')
	assert !cli.contains('proposals remain pending until the user approves them in the TUI')
	assert !cli.contains('Approved commands default to the platform OS sandbox')

	veasel := agent_system_message_for_provider('anthropic', 'ask', policy, true)
	assert veasel.contains('workspace_propose_file_edit')
	assert veasel.contains('workspace_propose_shell_command')
	assert veasel.contains('Approved commands default to the platform OS sandbox')
	assert !veasel.contains('installed provider CLI and its native tools')
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

fn test_non_interactive_ask_hides_side_effect_tools_from_the_model() {
	tools := [
		AgentToolDefinition{ name: 'workspace_read_file' },
		AgentToolDefinition{ name: 'workspace_propose_file_edit' },
		AgentToolDefinition{ name: 'workspace_propose_shell_command' },
		AgentToolDefinition{ name: 'mcp_tool' },
	]
	visible := restrict_agent_tools_for_execution_policy(tools, ExecutionPolicyTurn{
		mode:        .ask
		interactive: false
	})
	assert visible.map(it.name) == ['workspace_read_file']
	assert restrict_agent_tools_for_execution_policy(tools, ExecutionPolicyTurn{
		mode:        .ask
		interactive: true
	}).len == tools.len
}

fn test_non_interactive_code_change_final_response_cannot_claim_completion() {
	policy := ExecutionPolicyTurn{
		mode:        .ask
		interactive: false
	}
	response := agent_final_response_for_execution_policy('Implemented and tested.', true, policy,
		false, false)
	assert response.contains('was not completed')
	assert response.contains('Use the TUI for an interactive turn')
	assert agent_final_response_for_execution_policy('Read-only answer.', false, policy, false,
		false) == 'Read-only answer.'
	assert agent_final_response_for_execution_policy('I will implement this.', true,
		ExecutionPolicyTurn{
			mode:        .sandbox_auto
			interactive: false
		}, false, false).contains('No workspace edit was applied')
	assert agent_final_response_for_execution_policy('I implemented this.', true, ExecutionPolicyTurn{
		mode:        .sandbox_auto
		interactive: false
	}, true, false) == 'I implemented this.'
	assert agent_final_response_for_execution_policy('I implemented this.', true, ExecutionPolicyTurn{
		mode:        .ask
		interactive: true
	}, false, true).contains('pending human review')
}

fn test_installed_cli_final_response_uses_recorded_effects_and_does_not_overclaim_verification() {
	facts := TurnOutcomeFacts{
		edits_applied:    ['Write parse-env.mjs']
		commands_ran:     ['Bash (npm)']
		effects_observed: true
	}
	conflicting := agent_final_response_for_cli('No workspace edit was applied.', true,
		true, facts)
	assert conflicting.contains('conflicts with recorded native CLI effects')
	assert conflicting.contains('Write parse-env.mjs, Bash (npm)')
	assert conflicting.contains('did not independently verify')
	assert !conflicting.contains('tests passed')

	ordinary := agent_final_response_for_cli('I updated the parser.', true, false, facts)
	assert ordinary.contains('I updated the parser.')
	assert ordinary.contains('Veasel recorded native CLI edits')
	assert ordinary.contains('did not independently verify')
	assert ordinary.contains('any test result in the provider response is provider-reported')

	incomplete := agent_final_response_for_cli('The edit was applied, but npm test failed; this task is not complete.',
		true, true, facts)
	assert incomplete.contains('npm test failed')
	assert incomplete.contains('not complete')
	assert !incomplete.contains('conflicts with recorded')

	no_effects := agent_final_response_for_cli('I made the requested change.', true, false,
		TurnOutcomeFacts{ effects_observed: true })
	assert no_effects.contains('no successfully applied native edit or approved command')
	assert no_effects.contains('cannot confirm the requested code change')

	command_only := agent_final_response_for_cli('No workspace edit was applied; npm test passed.', true,
		true, TurnOutcomeFacts{
			commands_ran:     ['Bash (npm)']
			effects_observed: true
		})
	assert !command_only.contains('conflicts with recorded')
	assert command_only.contains('This does not establish that a code change was applied')
	assert command_only.contains('npm test passed')

	unobserved := agent_final_response_for_cli('Done.', true, false, TurnOutcomeFacts{})
	assert unobserved.contains('could not confirm whether')
	assert unobserved.contains('Done.')
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
