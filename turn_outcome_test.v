module main

import db.sqlite
import os
import uuid

fn edit_facts() TurnOutcomeFacts {
	return TurnOutcomeFacts{
		effects_observed: true
		edits_applied:    ['Edit math.js']
	}
}

// --- derivation -------------------------------------------------------------

fn test_clean_turn_without_effects_has_no_summary() {
	outcome := derive_turn_outcome('completed', TurnOutcomeFacts{ effects_observed: true }, '')
	assert outcome.outcome == 'completed'
	assert outcome.summary == ''
}

fn test_clean_turn_with_applied_edit_is_never_presented_as_verified() {
	outcome := derive_turn_outcome('completed', edit_facts(), '')
	assert outcome.outcome == 'completed'
	assert outcome.summary.contains('Edit math.js')
	assert outcome.summary.contains('not verified')
	assert outcome.facts.verification == 'not_reported'
}

fn test_denied_without_side_effects_says_nothing_was_applied() {
	outcome := derive_turn_outcome('completed', TurnOutcomeFacts{
		effects_observed: true
		approvals_denied: 1
		denied_tools:     ['Bash']
	}, '')
	assert outcome.outcome == 'completed_with_denials'
	assert outcome.summary.contains('1 denied')
	assert outcome.summary.contains('No changes were applied')
}

fn test_denials_on_a_provider_without_observation_do_not_claim_no_changes() {
	outcome := derive_turn_outcome('completed', TurnOutcomeFacts{
		approvals_denied: 1
		denied_tools:     ['Bash']
	}, '')
	assert outcome.outcome == 'completed_with_denials'
	assert !outcome.summary.contains('No changes were applied')
	assert outcome.summary.contains('could not observe')
}

fn test_applied_edit_with_expired_approval_lists_both() {
	outcome := derive_turn_outcome('completed', TurnOutcomeFacts{
		...edit_facts()
		approvals_approved: 1
		approvals_expired:  1
		expired_tools:      ['Bash']
	}, '')
	assert outcome.outcome == 'completed_with_denials'
	assert outcome.summary.contains('1 expired')
	assert outcome.summary.contains('Applied: Edit math.js')
	assert outcome.summary.contains('not verified')
}

fn test_failed_turn_with_applied_edit_is_partial_not_failed() {
	outcome := derive_turn_outcome('failed', TurnOutcomeFacts{
		...edit_facts()
		approvals_expired: 1
		expired_tools:     ['Bash']
	}, 'The assistant turn failed.')
	assert outcome.outcome == 'partial'
	assert outcome.summary.contains('Already applied: Edit math.js')
	assert outcome.summary.contains('1 expired')
	assert outcome.summary.contains('not verified')
	assert outcome.summary.contains('The assistant turn failed')
}

fn test_failed_turn_without_effects_stays_failed_with_the_public_error() {
	outcome := derive_turn_outcome('failed', TurnOutcomeFacts{ effects_observed: true },
		'Model provider rejected the API key (HTTP 401).')
	assert outcome.outcome == 'failed'
	assert outcome.summary == 'Model provider rejected the API key (HTTP 401).'
}

fn test_failed_turn_after_unobservable_approvals_is_uncertain() {
	outcome := derive_turn_outcome('failed', TurnOutcomeFacts{ approvals_approved: 2 },
		'The assistant turn failed.')
	assert outcome.outcome == 'uncertain'
	assert outcome.summary.contains('could not observe')
}

fn test_cancelled_turn_keeps_cancelled_and_lists_applied_work() {
	plain := derive_turn_outcome('cancelled', TurnOutcomeFacts{ effects_observed: true },
		'Turn cancelled.')
	assert plain.outcome == 'cancelled'
	assert plain.summary == 'Turn cancelled.'
	applied := derive_turn_outcome('cancelled', edit_facts(), 'Turn cancelled.')
	assert applied.outcome == 'cancelled'
	assert applied.summary.contains('Edit math.js')
	assert applied.summary.contains('not verified')
}

fn test_uncertain_turn_lists_applied_work() {
	outcome := derive_turn_outcome('uncertain', edit_facts(), 'The server stopped.')
	assert outcome.outcome == 'uncertain'
	assert outcome.summary.contains('Edit math.js')
}

// --- facts ------------------------------------------------------------------

fn test_facts_count_only_successful_edits_and_gated_commands() {
	mut facts := new_turn_facts(true)
	facts.note_tool_use('t1', 'Edit', '{"file_path":"/repo/src/math.js"}')
	facts.note_tool_use('t2', 'Edit', '{"file_path":"/repo/src/other.js"}')
	facts.note_tool_use('t3', 'Bash', '{"command":"npm test --token=secret"}')
	facts.note_tool_use('t4', 'Bash', '{"command":"git push origin main"}')
	facts.note_tool_use('t5', 'Read', '{"file_path":"/repo/README.md"}')
	facts.note_gated('t4')
	facts.note_tool_result('t1', false)
	facts.note_tool_result('t2', true) // the CLI reported a failure: not applied
	facts.note_tool_result('t3', false) // ungated command: not counted
	facts.note_tool_result('t4', false)
	facts.note_tool_result('t5', false)
	snapshot := facts.snapshot()
	assert snapshot.edits_applied == ['Edit math.js']
	assert snapshot.commands_ran == ['Bash (git)']
	// Arguments (which may carry secrets) never reach the summary.
	assert !snapshot.commands_ran.join(' ').contains('secret')
	assert snapshot.effects_observed
}

fn test_facts_record_each_decision_kind() {
	mut facts := new_turn_facts(false)
	facts.note_approval('Edit', 'approved')
	facts.note_approval('Bash', 'denied')
	facts.note_approval('Bash', 'expired')
	snapshot := facts.snapshot()
	assert snapshot.approvals_approved == 1
	assert snapshot.approvals_denied == 1
	assert snapshot.approvals_expired == 1
	assert snapshot.expired_tools == ['Bash']
}

// --- Claude protocol --------------------------------------------------------

fn test_claude_tool_uses_and_results_are_parsed_from_frames() {
	uses := claude_cli_tool_uses('{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"a","name":"Edit","input":{"file_path":"/x/y.js"}},{"type":"tool_use","id":"b","name":"Bash","input":{"command":"ls"}}]}}')
	assert uses.len == 2
	assert uses[0].id == 'a'
	assert uses[1].name == 'Bash'
	results := claude_cli_tool_results('{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"a","is_error":false,"content":"ok"},{"type":"tool_result","tool_use_id":"b","is_error":true,"content":"no"}]}}')
	assert results.len == 2
	assert !results[0].is_error
	assert results[1].is_error
	assert claude_cli_tool_results('not json').len == 0
	assert claude_cli_tool_uses('{"type":"result"}').len == 0
	approval := parse_claude_cli_line('{"type":"control_request","request_id":"r","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{},"tool_use_id":"b"}}')
	assert approval.approval_tool_id == 'b'
}

// --- migration 32 -----------------------------------------------------------

fn outcome_fixture(name string) string {
	return os.join_path(os.dir(@FILE), 'testing', 'fixtures', name)
}

fn ledger_version(path string) int {
	mut db := sqlite.connect(path) or { panic(err) }
	defer { db.close() or {} }
	return db.q_int('SELECT COALESCE(MAX(version), 0) FROM schema_migrations') or { panic(err) }
}

fn check_outcome_migration(fixture string, from_version int, session_count int) {
	root := os.join_path(os.temp_dir(), 'veasel-outcome-migrate-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'veasel.sqlite3')
	os.cp(outcome_fixture(fixture), path) or { panic(err) }
	assert ledger_version(path) == from_version

	mut store := open_store(path) or { panic(err) }
	sessions := store.list_sessions() or { panic(err) }
	assert sessions.len == session_count
	mut total_operations := 0
	for session in sessions {
		for operation in store.list_session_operations(session.id) or { panic(err) } {
			total_operations++
			// Turns recorded before the migration keep status as their truth.
			assert operation.outcome == ''
			assert operation.outcome_summary == ''
			assert operation.status in ['completed', 'failed']
		}
	}
	assert total_operations == 2
	// The new column accepts the full outcome vocabulary and rejects the rest.
	probe := sessions[0]
	for value in turn_outcome_values {
		store.db.exec_param_many('UPDATE session_operations SET outcome = ? WHERE session_id = ?',
			[value, probe.id]) or { panic('outcome ${value} rejected: ${err}') }
	}
	store.db.exec_param_many('UPDATE session_operations SET outcome = ? WHERE session_id = ?',
		['bogus', probe.id]) or {
		store.close() or { panic(err) }
		assert ledger_version(path) == latest_schema_version
		// Idempotent: reopening keeps the data and does not re-run anything.
		mut again := open_store(path) or { panic(err) }
		assert (again.list_sessions() or { panic(err) }).len == session_count
		again.close() or { panic(err) }
		assert ledger_version(path) == latest_schema_version
		return
	}
	assert false, 'the outcome CHECK must reject unknown values'
}

fn test_migration_32_from_real_v30_database() {
	check_outcome_migration('store_v30.sqlite', 30, 2)
}

fn test_migration_32_from_real_v31_database() {
	check_outcome_migration('store_v31.sqlite', 31, 1)
}

fn test_outcome_round_trips_through_the_operation_row_and_event() {
	root := os.join_path(os.temp_dir(), 'veasel-outcome-store-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{ title: 'o', directory: root }) or { panic(err) }
	operation_id := uuid.new_v4().str()
	store.create_session_operation(session.id, operation_id) or { panic(err) }
	outcome := derive_turn_outcome('failed', edit_facts(), 'The assistant turn failed.')
	store.record_session_turn_completion_with_outcome(session.id, operation_id, 'failed',
		outcome.summary, 'fix it', outcome.summary, outcome) or { panic(err) }
	operation := store.get_session_operation(session.id, operation_id) or { panic(err) }
	assert operation.status == 'failed'
	assert operation.outcome == 'partial'
	assert operation.outcome_summary.contains('Edit math.js')
	assert operation.outcome_facts.edits_applied == ['Edit math.js']
	assert operation.error == operation.outcome_summary
	events := store.db.exec_param("SELECT data FROM events WHERE session_id = ? AND type = 'session.turn_completed'",
		session.id) or { panic(err) }
	assert events.len == 1
	assert events[0].val(0).contains('"outcome":"partial"')
	// A bogus outcome never reaches the database.
	store.record_session_turn_completion_with_outcome(session.id, uuid.new_v4().str(), 'failed', 'x',
		'u', 'a', TurnOutcome{ outcome: 'bogus' }) or {
		assert err.msg() == 'turn outcome is invalid'
		return
	}
	assert false, 'invalid outcome accepted'
}

fn test_restart_recovery_marks_interrupted_turns_uncertain_in_outcome() {
	root := os.join_path(os.temp_dir(), 'veasel-outcome-recover-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'veasel.sqlite3')
	mut store := open_store(path) or { panic(err) }
	session := store.create_session(SessionInput{ title: 'r', directory: root }) or { panic(err) }
	operation_id := uuid.new_v4().str()
	store.create_session_operation(session.id, operation_id) or { panic(err) }
	store.close() or { panic(err) }
	mut reopened := open_store(path) or { panic(err) }
	defer { reopened.close() or {} }
	operation := reopened.get_session_operation(session.id, operation_id) or { panic(err) }
	assert operation.status == 'uncertain'
	assert operation.outcome == 'uncertain'
}
