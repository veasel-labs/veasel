module main

import os

// E2E against the scripted fake OpenCode ACP copied verbatim in PR #697
// (tests/focus_reference/testing/fake-opencode.mjs, from
// agent-toolkit@ac2cd125). Skips only when node is unavailable, so CI
// without node stays honest instead of silently passing.

struct AcpStreamedSink {
pub mut:
	text string
}

fn acp_node_available() bool {
	result := os.execute('node --version')
	return result.exit_code == 0
}

fn acp_fixture_shim() (string, bool) {
	if !acp_node_available() {
		eprintln('skip: node unavailable for fake-opencode fixture')
		return '', false
	}
	fixture := os.join_path('tests', 'focus_reference', 'testing', 'fake-opencode.mjs')
	if !os.exists(fixture) {
		eprintln('skip: fake-opencode fixture not present')
		return '', false
	}
	shim := os.join_path(os.temp_dir(), 'veasel-fake-opencode-test.sh')
	os.write_file(shim, '#!/bin/sh\nexec node "${os.abs_path(fixture)}" "$@"\n') or {
		panic(err)
	}
	os.chmod(shim, 0o755) or { panic(err) }
	return shim, true
}

fn test_run_opencode_cli_turn_against_fake_fixture() {
	shim, ok := acp_fixture_shim()
	if !ok {
		return
	}
	defer { os.rm(shim) or {} }
	mut sink := &AcpStreamedSink{}
	turn := run_opencode_cli_turn(shim, os.getwd(), '', 'hello', 30_000, fn [mut sink] (delta string) ! {
		sink.text += delta
	}, deny_all_cli_approvals) or { panic(err) }
	assert turn.outcome == 'completed'
	assert turn.session_id == 'ses_fake_focus_1'
	assert turn.text == 'ACP_OK'
	assert sink.text == 'ACP_OK'
	assert turn.usage_reported
	assert turn.usage.input_tokens == 3
	assert turn.usage.output_tokens == 2
}

fn test_run_opencode_cli_turn_denies_permission_fail_closed() {
	shim, ok := acp_fixture_shim()
	if !ok {
		return
	}
	defer { os.rm(shim) or {} }
	turn := run_opencode_cli_turn(shim, os.getwd(), '', 'approval', 30_000,
		ignore_provider_text_delta, deny_all_cli_approvals) or { panic(err) }
	assert turn.outcome == 'completed'
	assert turn.approvals_denied == 1
	assert turn.approvals_approved == 0
	assert turn.text.contains('Not allowed.')
}

fn test_run_opencode_cli_turn_allows_only_explicit_permission() {
	shim, ok := acp_fixture_shim()
	if !ok {
		return
	}
	defer { os.rm(shim) or {} }
	allow := fn (request_id string, tool_name string, input_json string) bool {
		return request_id.starts_with('opencode-') && input_json.contains('touch result.txt')
	}
	turn := run_opencode_cli_turn(shim, os.getwd(), '', 'approval', 30_000,
		ignore_provider_text_delta, allow) or { panic(err) }
	assert turn.outcome == 'completed'
	assert turn.approvals_approved == 1
	assert turn.text.contains('Allowed once.')
}

fn test_run_opencode_cli_turn_declines_questions() {
	shim, ok := acp_fixture_shim()
	if !ok {
		return
	}
	defer { os.rm(shim) or {} }
	turn := run_opencode_cli_turn(shim, os.getwd(), '', 'question', 30_000,
		ignore_provider_text_delta, deny_all_cli_approvals) or { panic(err) }
	assert turn.outcome == 'completed'
	assert turn.text.contains('Question cancelled.')
}
