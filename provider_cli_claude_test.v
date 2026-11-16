module main

// Fixture frames mirror tests/focus_reference/testing/fake-claude.mjs
// (copied verbatim in PR #697 from agent-toolkit@ac2cd125).

fn test_parse_claude_cli_init_frame() {
	event := parse_claude_cli_line('{"type":"system","subtype":"init","session_id":"sess-fake-1","model":"fake-model-1","permissionMode":"default"}')
	assert event.kind == 'init'
	assert event.session_id == 'sess-fake-1'
	assert event.model == 'fake-model-1'
}

fn test_parse_claude_cli_text_delta() {
	event := parse_claude_cli_line('{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}}}')
	assert event.kind == 'text_delta'
	assert event.text == 'hello'
}

fn test_parse_claude_cli_tool_use_and_approval() {
	tool := parse_claude_cli_line('{"type":"assistant","message":{"id":"msg_w","content":[{"type":"tool_use","id":"toolu_w","name":"Bash","input":{"command":"ls"}}]}}')
	assert tool.kind == 'tool_use'
	assert tool.tool_id == 'toolu_w'
	assert tool.tool_name == 'Bash'
	approval := parse_claude_cli_line('{"type":"control_request","request_id":"req-1","request":{"subtype":"can_use_tool","tool_name":"Bash"}}')
	assert approval.kind == 'approval_request'
	assert approval.request_id == 'req-1'
	assert approval.tool_name == 'Bash'
}

fn test_parse_claude_cli_result_usage_is_adapter_reported() {
	event := parse_claude_cli_line('{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"usage":{"input_tokens":10,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":5},"session_id":"sess-fake-1"}')
	assert event.kind == 'result'
	assert event.outcome == 'completed'
	assert event.usage_reported
	assert event.usage.input_tokens == 12 // input + cache creation, per TS reference
	assert event.usage.cache_read_tokens == 3
	assert event.usage.output_tokens == 5
	assert event.usage.reported
	cost := event.reported_cost_usd or { panic('expected reported cost') }
	assert cost == 0.01
}

fn test_parse_claude_cli_result_without_usage_never_invents_it() {
	event := parse_claude_cli_line('{"type":"result","subtype":"error_max_turns","session_id":"s1"}')
	assert event.kind == 'result'
	assert event.outcome == 'failed'
	assert !event.usage_reported
	assert !event.usage.reported
	assert event.reported_cost_usd == none
}

fn test_parse_claude_cli_malformed_and_unknown_frames_are_other() {
	assert parse_claude_cli_line('').kind == 'other'
	assert parse_claude_cli_line('not json').kind == 'other'
	assert parse_claude_cli_line('{"type":"future_frame"}').kind == 'other'
}

fn test_claude_cli_args_fail_closed() {
	args := claude_cli_args('nonsense-mode', '--evil')
	assert args.contains('default')
	assert !args.contains('--resume') // unsafe resume id rejected
	resumed := claude_cli_args('accept-edits', 'sess-fake-1')
	assert resumed.contains('acceptEdits')
	assert resumed[resumed.len - 2] == '--resume'
	assert resumed[resumed.len - 1] == 'sess-fake-1'
	assert claude_permission_mode_arg('bypass') == 'bypassPermissions'
	assert !is_safe_claude_session_id('')
	assert !is_safe_claude_session_id('a/b')
	assert is_safe_claude_session_id('abc-123_X.y')
}
