module main

import x.json2

// Fixture frames mirror tests/focus_reference/testing/fake-opencode.mjs
// (copied verbatim in PR #697 from agent-toolkit@ac2cd125).

fn test_parse_opencode_message_and_reasoning_chunks() {
	text := parse_opencode_cli_line('{"method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}}}',
		's1')
	assert text.kind == 'text_delta'
	assert text.text == 'hi'
	reasoning := parse_opencode_cli_line('{"method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"think"}}}}',
		's1')
	assert reasoning.kind == 'reasoning_delta'
	tool := parse_opencode_cli_line('{"method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"t1"}}}',
		's1')
	assert tool.kind == 'tool_call'
	assert tool.tool_id == 't1'
}

fn test_parse_opencode_other_session_frames_are_ignored() {
	child := parse_opencode_cli_line('{"method":"session/update","params":{"sessionId":"child","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"private"}}}}',
		's1')
	assert child.kind == 'other'
	assert parse_opencode_cli_line('garbage', 's1').kind == 'other'
}

fn test_parse_opencode_permission_requires_reject_option() {
	safe := parse_opencode_cli_line('{"id":7,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t1"},"options":[{"optionId":"a","kind":"allow_once"},{"optionId":"r","kind":"reject_once"}]}}',
		's1')
	assert safe.kind == 'approval_request'
	assert safe.can_allow_once
	unsafe_event := parse_opencode_cli_line('{"id":8,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t1"},"options":[{"optionId":"a","kind":"allow_always"}]}}',
		's1')
	assert unsafe_event.kind == 'approval_unsafe' // caller must cancel: cannot be rejected
}

fn test_opencode_prompt_result_outcome_and_usage_truth() {
	result := json2.decode[map[string]json2.Any]('{"stopReason":"end_turn","usage":{"inputTokens":10,"outputTokens":5}}') or {
		panic(err)
	}
	outcome := parse_opencode_prompt_result(result)
	assert outcome.outcome == 'completed'
	assert outcome.usage_reported
	assert outcome.usage.input_tokens == 10
	assert outcome.usage.output_tokens == 5
	assert outcome.usage.reported_cost_usd == none // ACP reports no cost; never estimated
	cancelled := parse_opencode_prompt_result(json2.decode[map[string]json2.Any]('{"stopReason":"cancelled"}') or {
		panic(err)
	})
	assert cancelled.outcome == 'interrupted'
	assert !cancelled.usage_reported
	failed := parse_opencode_prompt_result(json2.decode[map[string]json2.Any]('{"stopReason":"max_tokens"}') or {
		panic(err)
	})
	assert failed.outcome == 'failed'
}

fn test_opencode_permission_mode_fails_closed() {
	assert opencode_permission_mode_supported('ask')
	assert !opencode_permission_mode_supported('accept-edits')
	assert !opencode_permission_mode_supported('bypass')
	assert !opencode_permission_mode_supported('')
}
