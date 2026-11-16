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
	question := parse_codex_cli_line('{"id":"question","method":"item/tool/requestUserInput","params":{"threadId":"parent","turnId":"turn-1","itemId":"q"}}',
		'parent')
	assert question.kind == 'user_input_request'
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
