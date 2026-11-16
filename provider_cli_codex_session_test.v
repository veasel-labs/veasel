module main

import os

// E2E against the scripted fake Codex copied verbatim in PR #697
// (tests/focus_reference/testing/fake-codex.mjs, from
// agent-toolkit@ac2cd125). Skips only when node is unavailable, so CI
// without node stays honest instead of silently passing.

struct CodexStreamedSink {
pub mut:
	text string
}

fn codex_node_available() bool {
	result := os.execute('node --version')
	return result.exit_code == 0
}

fn codex_fixture_shim() (string, bool) {
	if !codex_node_available() {
		eprintln('skip: node unavailable for fake-codex fixture')
		return '', false
	}
	fixture := os.join_path('tests', 'focus_reference', 'testing', 'fake-codex.mjs')
	if !os.exists(fixture) {
		eprintln('skip: fake-codex fixture not present')
		return '', false
	}
	shim := os.join_path(os.temp_dir(), 'veasel-fake-codex-test.sh')
	os.write_file(shim, '#!/bin/sh\nexec node "${os.abs_path(fixture)}" "$@"\n') or {
		panic(err)
	}
	os.chmod(shim, 0o755) or { panic(err) }
	return shim, true
}

fn test_run_codex_cli_turn_against_fake_fixture() {
	shim, ok := codex_fixture_shim()
	if !ok {
		return
	}
	defer { os.rm(shim) or {} }
	mut sink := &CodexStreamedSink{}
	turn := run_codex_cli_turn(shim, os.getwd(), 'ask', '', 'scope', 30_000, fn [mut sink] (delta string) ! {
		sink.text += delta
	}, deny_all_cli_approvals) or { panic(err) }
	assert turn.outcome == 'completed'
	assert turn.thread_id == 'parent'
	assert turn.model == 'test-model'
	// Child-thread text must never leak into the parent turn.
	assert !turn.text.contains('private child text')
	assert turn.approvals_denied == 0
	assert !turn.usage_reported
}

fn test_run_codex_cli_turn_denies_approvals_fail_closed() {
	shim, ok := codex_fixture_shim()
	if !ok {
		return
	}
	defer { os.rm(shim) or {} }
	turn := run_codex_cli_turn(shim, os.getwd(), 'ask', '', 'approval', 30_000,
		ignore_provider_text_delta, deny_all_cli_approvals) or { panic(err) }
	assert turn.outcome == 'completed'
	assert turn.approvals_denied == 1
	assert turn.approvals_approved == 0
	// The fake echoes the decision as the final agent message text.
	assert turn.text == 'decline'
}

fn test_run_codex_cli_turn_allows_only_explicit_approval() {
	shim, ok := codex_fixture_shim()
	if !ok {
		return
	}
	defer { os.rm(shim) or {} }
	allow := fn (request_id string, tool_name string, input_json string) bool {
		return request_id.starts_with('codex-') && tool_name.len > 0 && input_json.contains('yes')
	}
	turn := run_codex_cli_turn(shim, os.getwd(), 'ask', '', 'approval', 30_000,
		ignore_provider_text_delta, allow) or { panic(err) }
	assert turn.outcome == 'completed'
	assert turn.approvals_approved == 1
	assert turn.text == 'accept'
}

fn test_run_codex_cli_turn_usage_is_never_published() {
	shim, ok := codex_fixture_shim()
	if !ok {
		return
	}
	defer { os.rm(shim) or {} }
	turn := run_codex_cli_turn(shim, os.getwd(), 'ask', '', 'usage', 30_000,
		ignore_provider_text_delta, deny_all_cli_approvals) or { panic(err) }
	assert turn.outcome == 'completed'
	assert !turn.usage_reported
}

fn test_codex_deny_decision_respects_available_decisions() {
	assert codex_deny_decision(['accept', 'decline']) == 'decline'
	assert codex_deny_decision(['accept', 'cancel']) == 'cancel'
	assert codex_deny_decision([]string{}) == 'decline'
	assert codex_deny_decision(['cancel']) == 'cancel'
}
