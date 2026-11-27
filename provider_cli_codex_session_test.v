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
	turn := run_codex_cli_turn(shim, os.getwd(), 'ask', '', '', 'scope', 30_000, fn [mut sink] (delta string) ! {
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
	turn := run_codex_cli_turn(shim, os.getwd(), 'ask', '', '', 'approval', 30_000,
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
	turn := run_codex_cli_turn(shim, os.getwd(), 'ask', '', '', 'approval', 30_000,
		ignore_provider_text_delta, allow) or { panic(err) }
	assert turn.outcome == 'completed'
	assert turn.approvals_approved == 1
	assert turn.text == 'accept'
}

fn test_run_codex_cli_turn_records_redacted_effect_receipts() {
	shim, ok := codex_fixture_shim()
	if !ok {
		return
	}
	defer { os.rm(shim) or {} }
	mut facts := new_turn_facts(false)
	approve := fn [mut facts] (request_id string, tool_name string, _ string) bool {
		facts.note_approval(tool_name, 'approved')
		return request_id.starts_with('codex-')
	}
	_ := run_codex_cli_turn_cancellable_observed(shim, os.getwd(), 'ask', '', '', 'effects',
		30_000, ignore_provider_text_delta, approve, unsafe { nil }, facts) or { panic(err) }
	snapshot := facts.snapshot()
	assert snapshot.approvals_approved == 1
	assert snapshot.commands_ran == ['Bash']
	assert snapshot.edits_applied == ['Edit']
	assert snapshot.effects_observed
	outcome := derive_turn_outcome('completed', snapshot, '')
	serialized := turn_outcome_detail_json(outcome)
	assert outcome.summary.contains('Bash')
	assert outcome.summary.contains('Edit')
	assert !serialized.contains('secret-command-argument')
	assert !serialized.contains('secret-command-output')
	assert !serialized.contains('private-sentinel.md')
}

fn test_run_codex_cli_turn_denial_does_not_record_unrun_command() {
	shim, ok := codex_fixture_shim()
	if !ok {
		return
	}
	defer { os.rm(shim) or {} }
	mut facts := new_turn_facts(false)
	deny := fn [mut facts] (_ string, tool_name string, _ string) bool {
		facts.note_approval(tool_name, 'denied')
		return false
	}
	_ := run_codex_cli_turn_cancellable_observed(shim, os.getwd(), 'ask', '', '', 'effects-denied',
		30_000, ignore_provider_text_delta, deny, unsafe { nil }, facts) or { panic(err) }
	snapshot := facts.snapshot()
	assert snapshot.approvals_denied == 1
	assert snapshot.commands_ran.len == 0
	assert snapshot.edits_applied.len == 0
	assert snapshot.effects_observed
	outcome := derive_turn_outcome('completed', snapshot, '')
	assert outcome.outcome == 'completed_with_denials'
	assert outcome.summary.contains('No changes were applied.')
}

fn test_run_codex_cli_turn_keeps_incomplete_effects_uncertain() {
	shim, ok := codex_fixture_shim()
	if !ok {
		return
	}
	defer { os.rm(shim) or {} }
	mut facts := new_turn_facts(false)
	approve := fn [mut facts] (_ string, tool_name string, _ string) bool {
		facts.note_approval(tool_name, 'approved')
		return true
	}
	_ := run_codex_cli_turn_cancellable_observed(shim, os.getwd(), 'ask', '', '', 'effects-incomplete',
		30_000, ignore_provider_text_delta, approve, unsafe { nil }, facts) or { panic(err) }
	snapshot := facts.snapshot()
	assert snapshot.approvals_approved == 1
	assert snapshot.unresolved_effects == 1
	assert snapshot.commands_ran.len == 0
	assert !snapshot.effects_observed
	outcome := derive_turn_outcome('completed', snapshot, '')
	assert outcome.outcome == 'uncertain'
	assert outcome.summary.contains('could not confirm the outcome')
	assert !turn_outcome_detail_json(outcome).contains('secret-command-argument')
}

fn test_run_codex_cli_turn_approval_without_item_start_or_result_is_uncertain() {
	shim, ok := codex_fixture_shim()
	if !ok {
		return
	}
	defer { os.rm(shim) or {} }
	mut facts := new_turn_facts(false)
	approve := fn [mut facts] (_ string, tool_name string, _ string) bool {
		facts.note_approval(tool_name, 'approved')
		return true
	}
	_ := run_codex_cli_turn_cancellable_observed(shim, os.getwd(), 'ask', '', '',
		'effects-approval-incomplete', 30_000, ignore_provider_text_delta, approve, unsafe { nil },
		facts) or { panic(err) }
	snapshot := facts.snapshot()
	assert snapshot.approvals_approved == 1
	assert snapshot.unresolved_effects == 1
	outcome := derive_turn_outcome('completed', snapshot, '')
	assert outcome.outcome == 'uncertain'
	assert outcome.summary.contains('could not confirm the outcome')
}

fn test_run_codex_cli_turn_records_successful_bypass_command_receipt() {
	shim, ok := codex_fixture_shim()
	if !ok {
		return
	}
	defer { os.rm(shim) or {} }
	mut facts := new_turn_facts(false)
	_ := run_codex_cli_turn_cancellable_observed(shim, os.getwd(), 'bypass', '', '', 'effects-bypass',
		30_000, ignore_provider_text_delta, deny_all_cli_approvals, unsafe { nil }, facts) or {
		panic(err)
	}
	snapshot := facts.snapshot()
	assert snapshot.commands_ran == ['Bash']
	assert snapshot.unresolved_effects == 0
	assert snapshot.effects_observed
	outcome := derive_turn_outcome('completed', snapshot, '')
	assert outcome.outcome == 'completed'
	assert outcome.summary.contains('Applied: Bash')
	serialized := turn_outcome_detail_json(outcome)
	assert !serialized.contains('secret-command-argument')
	assert !serialized.contains('secret-command-output')
}

fn test_run_codex_cli_turn_usage_is_never_published() {
	shim, ok := codex_fixture_shim()
	if !ok {
		return
	}
	defer { os.rm(shim) or {} }
	turn := run_codex_cli_turn(shim, os.getwd(), 'ask', '', '', 'usage', 30_000,
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

fn test_codex_handshake_drains_stderr_and_ignores_unrelated_response() {
	shim := os.join_path(os.temp_dir(), 'veasel-codex-rpc-order-${os.getpid()}.sh')
	defer { os.rm(shim) or {} }
	os.write_file(shim, '#!/bin/sh
IFS= read -r request
dd if=/dev/zero bs=65536 count=4 1>&2 2>/dev/null
printf \'%s\\n\' \'{"id":1,"result":{}}\' \'{"id":99,"result":{}}\'
IFS= read -r notification
IFS= read -r request
printf \'%s\\n\' \'{"id":2,"result":{"thread":{"id":"parent"}}}\'
IFS= read -r request
printf \'%s\\n\' \'{"id":3,"result":{"turn":{"id":"turn"}}}\' \'{"method":"turn/completed","params":{"threadId":"parent","turn":{"id":"turn","status":"completed"}}}\'
') or { panic(err) }
	os.chmod(shim, 0o700) or { panic(err) }
	turn := run_codex_cli_turn(shim, os.getwd(), 'ask', '', '', 'scope', 5_000,
		ignore_provider_text_delta, deny_all_cli_approvals) or { panic(err) }
	assert turn.outcome == 'completed'
	assert turn.thread_id == 'parent'
}

fn test_codex_handshake_explains_early_eof() {
	shim := os.join_path(os.temp_dir(), 'veasel-codex-rpc-eof-${os.getpid()}.sh')
	defer { os.rm(shim) or {} }
	os.write_file(shim, '#!/bin/sh\nIFS= read -r request\nexit 7\n') or { panic(err) }
	os.chmod(shim, 0o700) or { panic(err) }
	run_codex_cli_turn(shim, os.getwd(), 'ask', '', '', 'scope', 5_000,
		ignore_provider_text_delta, deny_all_cli_approvals) or {
		assert err.msg().contains('exit 7, handshake phase 0'), err.msg()
		return
	}
	assert false, 'unexpected turn completion after native CLI exited'
}
