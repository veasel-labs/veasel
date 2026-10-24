module main

import os
import uuid

fn test_subagent_run_is_idempotent_bounded_and_delivered_once_after_restart() {
	root := os.join_path(os.temp_dir(), 'veasel-subagent-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	db_path := os.join_path(root, 'veasel.sqlite3')
	mut store := open_store(db_path) or { panic(err) }
	parent := store.create_session(SessionInput{ title: 'Parent', directory: root }) or { panic(err) }
	operation_id := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, operation_id) or { panic(err) }
	first := store.create_subagent_run(parent.id, operation_id, 'request-1', 'trusted-reviewer', 1,
		'Child', root) or { panic(err) }
	retry := store.create_subagent_run(parent.id, operation_id, 'request-1', 'trusted-reviewer', 1,
		'Child', root) or { panic(err) }
	assert retry.id == first.id
	assert retry.child_session_id == first.child_session_id
	assert first.status == 'queued'
	_ = store.create_subagent_run(parent.id, operation_id, 'request-1', 'different-agent', 1,
		'Child', root) or {
		assert err.msg().contains('reused with different parameters')
		SubagentRun{}
	}
	_ = store.begin_subagent_run(first.id) or { panic(err) }
	_ = store.finish_subagent_run(first.id, 'completed', 'review complete', '') or { panic(err) }
	outcome := store.claim_subagent_outcome(first.id) or { panic(err) }
	assert outcome.result == 'review complete'
	assert outcome.outcome_claimed
	_ = store.claim_subagent_outcome(first.id) or {
		assert err.msg().contains('already claimed')
		SubagentRun{}
	}
	queued := store.create_subagent_run(parent.id, operation_id, 'request-2', 'trusted-reviewer', 1,
		'Queued child', root) or { panic(err) }
	_ = store.append_exchange(parent.id, operation_id, 'parent task', 'done', '', '', '', ProviderUsage{}) or { panic(err) }
	assert (store.get_subagent_run_unlocked(queued.id) or { panic(err) }).status == 'cancelled'
	store.close() or { panic(err) }

	mut recovered := open_store(db_path) or { panic(err) }
	defer { recovered.close() or {} }
	restored := recovered.get_subagent_run_unlocked(first.id) or { panic(err) }
	assert restored.status == 'completed'
	assert restored.outcome_claimed
}

fn test_subagent_schema_migrates_existing_v17_database() {
	root := os.join_path(os.temp_dir(), 'veasel-subagent-migration-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	db_path := os.join_path(root, 'veasel.sqlite3')
	mut store := open_store(db_path) or { panic(err) }
	initial_version := store.db.q_int('SELECT MAX(version) FROM schema_migrations') or { panic(err) }
	assert initial_version == 18
	_ = store.db.exec('DROP TABLE subagent_runs') or { panic(err) }
	_ = store.db.exec('DELETE FROM schema_migrations WHERE version = 18') or { panic(err) }
	store.close() or { panic(err) }
	mut migrated := open_store(db_path) or { panic(err) }
	defer { migrated.close() or {} }
	assert migrated.db.q_int("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'subagent_runs'") or {
		panic(err)
	} == 1
	migrated_version := migrated.db.q_int('SELECT MAX(version) FROM schema_migrations') or { panic(err) }
	assert migrated_version == 18
}

fn test_subagent_run_enforces_concurrency_and_marks_running_as_uncertain() {
	root := os.join_path(os.temp_dir(), 'veasel-subagent-recovery-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	db_path := os.join_path(root, 'veasel.sqlite3')
	mut store := open_store(db_path) or { panic(err) }
	parent := store.create_session(SessionInput{ title: 'Parent', directory: root }) or { panic(err) }
	operation_id := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, operation_id) or { panic(err) }
	mut running_ids := []string{cap: max_active_subagent_runs_per_parent}
	for i in 0 .. max_active_subagent_runs_per_parent {
		run := store.create_subagent_run(parent.id, operation_id, 'request-${i}', 'trusted-worker', 1,
			'Child ${i}', root) or { panic(err) }
		_ = store.begin_subagent_run(run.id) or { panic(err) }
		running_ids << run.id
	}
	over_limit := store.create_subagent_run(parent.id, operation_id, 'request-over-limit', 'trusted-worker', 1,
		'Overflow', root) or {
		assert err.msg().contains('concurrency limit')
		SubagentRun{}
	}
	assert over_limit.id == ''
	_ = store.finish_subagent_run(running_ids[0], 'failed', '', 'finished before restart') or {
		panic(err)
	}
	queued := store.create_subagent_run(parent.id, operation_id, 'request-after-slot-release',
		'trusted-worker', 1, 'Queued at restart', root) or { panic(err) }
	store.close() or { panic(err) }
	mut recovered := open_store(db_path) or { panic(err) }
	defer { recovered.close() or {} }
	for i, id in running_ids {
		run := recovered.get_subagent_run_unlocked(id) or { panic(err) }
		assert run.status == if i == 0 { 'failed' } else { 'uncertain' }
	}
	assert (recovered.get_subagent_run_unlocked(queued.id) or { panic(err) }).status == 'cancelled'
	outcome := recovered.claim_subagent_outcome(running_ids[1]) or { panic(err) }
	assert outcome.status == 'uncertain'
}
