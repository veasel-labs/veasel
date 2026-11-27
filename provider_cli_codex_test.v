module main

// Fixture frames mirror tests/focus_reference/testing/fake-codex.mjs
// (copied verbatim in PR #697 from agent-toolkit@ac2cd125).

fn test_parse_codex_text_and_reasoning_deltas() {
	text := parse_codex_cli_line('{"method":"item/agentMessage/delta","params":{"threadId":"parent","turnId":"turn-1","itemId":"m1","delta":"hi"}}',
		'parent')
	assert text.kind == 'text_delta'
	assert text.text == 'hi'
	reasoning := parse_codex_cli_line('{"method":"item/reasoning/textDelta","params":{"threadId":"parent","itemId":"r1","delta":"think"}}',
		'parent')
	assert reasoning.kind == 'reasoning_delta'
}

fn test_parse_codex_child_thread_frames_are_ignored() {
	child := parse_codex_cli_line('{"method":"item/agentMessage/delta","params":{"threadId":"child","turnId":"child-turn","itemId":"child-message","delta":"private child text"}}',
		'parent')
	assert child.kind == 'other'
}

fn test_parse_codex_turn_lifecycle_and_approvals() {
	started := parse_codex_cli_line('{"method":"turn/started","params":{"threadId":"parent","turn":{"id":"turn-1"}}}',
		'parent')
	assert started.kind == 'turn_started'
	assert started.turn_id == 'turn-1'
	done := parse_codex_cli_line('{"method":"turn/completed","params":{"threadId":"parent","turn":{"id":"turn-1","status":"completed"}}}',
		'parent')
	assert done.kind == 'turn_completed'
	assert done.outcome == 'completed'
	approval := parse_codex_cli_line('{"id":"a1","method":"item/commandExecution/requestApproval","params":{"threadId":"parent","turnId":"turn-1","itemId":"cmd","command":"rm file"}}',
		'parent')
	assert approval.kind == 'approval_request'
	assert approval.request_id == 'a1'
	legacy_approval := parse_codex_cli_line('{"id":"a2","method":"execCommandApproval","params":{"threadId":"parent","turnId":"turn-1","callId":"legacy-cmd","command":"python3"}}',
		'parent')
	assert legacy_approval.kind == 'approval_request'
	assert legacy_approval.item_id == 'legacy-cmd'
	question := parse_codex_cli_line('{"id":"question","method":"item/tool/requestUserInput","params":{"threadId":"parent","turnId":"turn-1","itemId":"q"}}',
		'parent')
	assert question.kind == 'user_input_request'
}

fn test_parse_codex_native_effect_items_without_retaining_payloads() {
	started := parse_codex_cli_line('{"method":"item/started","params":{"threadId":"parent","turnId":"turn-1","item":{"id":"cmd-1","type":"commandExecution","command":"python3 secret-argument"}}}',
		'parent')
	assert started.kind == 'tool_started'
	assert started.item_id == 'cmd-1'
	assert started.tool_name == 'Bash'
	assert !started.text.contains('secret-argument')
	command := parse_codex_cli_line('{"method":"item/completed","params":{"threadId":"parent","turnId":"turn-1","item":{"id":"cmd-1","type":"commandExecution","status":"completed","exitCode":0,"aggregatedOutput":"secret-output"}}}',
		'parent')
	assert command.kind == 'tool_completed'
	assert command.tool_name == 'Bash'
	assert command.succeeded
	assert !command.text.contains('secret-output')
	failed_command := parse_codex_cli_line('{"method":"item/completed","params":{"threadId":"parent","turnId":"turn-1","item":{"id":"cmd-2","type":"commandExecution","status":"completed","exitCode":2}}}',
		'parent')
	assert !failed_command.succeeded
	null_exit_code := parse_codex_cli_line('{"method":"item/completed","params":{"threadId":"parent","turnId":"turn-1","item":{"id":"cmd-null-exit","type":"commandExecution","status":"completed","exitCode":null}}}',
		'parent')
	assert null_exit_code.succeeded
	edit := parse_codex_cli_line('{"method":"item/completed","params":{"threadId":"parent","turnId":"turn-1","item":{"id":"edit-1","type":"fileChange","status":"completed","changes":[{"path":"private-sentinel.md"}]}}}',
		'parent')
	assert edit.kind == 'tool_completed'
	assert edit.tool_name == 'Edit'
	assert edit.succeeded
	assert !edit.text.contains('private-sentinel.md')
	missing_edit_status := parse_codex_cli_line('{"method":"item/completed","params":{"threadId":"parent","turnId":"turn-1","item":{"id":"edit-missing-status","type":"fileChange","changes":[]}}}',
		'parent')
	assert !missing_edit_status.succeeded
	untracked := parse_codex_cli_line('{"method":"item/started","params":{"threadId":"parent","turnId":"turn-1","item":{"id":"mcp-1","type":"mcpToolCall","server":"private-server","tool":"write","arguments":{"token":"secret"}}}}',
		'parent')
	assert untracked.kind == 'untracked_tool'
	assert untracked.item_id == 'mcp-1'
	assert !untracked.text.contains('private-server')
	untracked_completed := parse_codex_cli_line('{"method":"item/completed","params":{"threadId":"parent","turnId":"turn-1","item":{"id":"dynamic-1","type":"dynamicToolCall","tool":"private-tool"}}}',
		'parent')
	assert untracked_completed.kind == 'untracked_tool'
	assert untracked_completed.item_id == 'dynamic-1'
	generated_image := parse_codex_cli_line('{"method":"item/started","params":{"threadId":"parent","turnId":"turn-1","item":{"id":"image-1","type":"imageGeneration"}}}',
		'parent')
	assert generated_image.kind == 'untracked_tool'
	unknown_started := parse_codex_cli_line('{"method":"item/started","params":{"threadId":"parent","turnId":"turn-1","item":{"id":"future-1","type":"futureEffect"}}}',
		'parent')
	assert unknown_started.kind == 'untracked_tool'
	assert unknown_started.item_id == 'future-1'
	unknown_completed := parse_codex_cli_line('{"method":"item/completed","params":{"threadId":"parent","turnId":"turn-1","item":{"id":"future-1","type":"futureEffect","status":"completed"}}}',
		'parent')
	assert unknown_completed.kind == 'untracked_tool'
	assert unknown_completed.item_id == 'future-1'
	reasoning_started := parse_codex_cli_line('{"method":"item/started","params":{"threadId":"parent","turnId":"turn-1","item":{"id":"reasoning-1","type":"reasoning","text":"private reasoning"}}}',
		'parent')
	assert reasoning_started.kind == 'other'
	reasoning_completed := parse_codex_cli_line('{"method":"item/completed","params":{"threadId":"parent","turnId":"turn-1","item":{"id":"reasoning-1","type":"reasoning","text":"private reasoning"}}}',
		'parent')
	assert reasoning_completed.kind == 'other'
	web_search := parse_codex_cli_line('{"method":"item/completed","params":{"threadId":"parent","turnId":"turn-1","item":{"id":"search-1","type":"webSearch","query":"private query"}}}',
		'parent')
	assert web_search.kind == 'other'
	sleep_started := parse_codex_cli_line('{"method":"item/started","params":{"threadId":"parent","turnId":"turn-1","item":{"id":"sleep-1","type":"Extension","kind":"clock.sleep","durationMs":1000}}}',
		'parent')
	assert sleep_started.kind == 'other'
	sleep_completed := parse_codex_cli_line('{"method":"item/completed","params":{"threadId":"parent","turnId":"turn-1","item":{"id":"sleep-1","type":"Extension","kind":"clock.sleep","durationMs":1000}}}',
		'parent')
	assert sleep_completed.kind == 'other'
	other_extension := parse_codex_cli_line('{"method":"item/completed","params":{"threadId":"parent","turnId":"turn-1","item":{"id":"extension-1","type":"Extension","kind":"image_gen.generation"}}}',
		'parent')
	assert other_extension.kind == 'untracked_tool'
	function_output := parse_codex_cli_line('{"method":"item/completed","params":{"threadId":"parent","turnId":"turn-1","item":{"id":"function-output-1","type":"functionCallOutput","output":"private output"}}}',
		'parent')
	assert function_output.kind == 'untracked_tool'
	declined := parse_codex_cli_line('{"method":"item/completed","params":{"threadId":"parent","turnId":"turn-1","item":{"id":"cmd-3","type":"commandExecution","status":"declined"}}}',
		'parent')
	assert declined.effect_free
	canceled := parse_codex_cli_line('{"method":"item/completed","params":{"threadId":"parent","turnId":"turn-1","item":{"id":"cmd-4","type":"commandExecution","status":"canceled"}}}',
		'parent')
	assert !canceled.effect_free
	interrupted := parse_codex_cli_line('{"method":"turn/completed","params":{"threadId":"parent","turn":{"id":"turn-1","status":"interrupted"}}}',
		'parent')
	assert interrupted.kind == 'turn_completed'
	assert interrupted.outcome == 'interrupted'
}

fn test_parse_codex_usage_is_never_published_as_turn_spend() {
	usage := parse_codex_cli_line('{"method":"thread/tokenUsage/updated","params":{"threadId":"parent","turnId":"turn-1","tokenUsage":{"last":{"inputTokens":80},"total":{"inputTokens":800}}}}',
		'parent')
	assert usage.kind == 'usage_not_published'
	assert parse_codex_cli_line('garbage', 'parent').kind == 'other'
	assert parse_codex_cli_line('', 'parent').kind == 'other'
}

fn test_codex_policy_fails_closed() {
	ask := codex_policy('ask')
	assert ask.approval_policy == 'on-request'
	assert ask.sandbox == 'read-only'
	assert codex_policy('unknown-mode').sandbox == 'read-only'
	assert codex_policy('accept-edits').sandbox == 'workspace-write'
	assert codex_policy('plan').approval_policy == 'never'
	assert codex_policy('bypass').sandbox == 'danger-full-access'
}
