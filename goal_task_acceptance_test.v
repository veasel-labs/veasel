module main

import os
import rand

fn test_goal_task_acceptance_request_requires_exact_string_fields_and_decision() {
	candidate := 'a'.repeat(40)
	parsed := parse_goal_task_acceptance_request('{"attempt":"2","candidate_sha":"${candidate}","decision":"accept"}') or {
		panic(err)
	}
	assert parsed.attempt == 2
	assert parsed.candidate_sha == candidate
	assert parsed.decision == 'accept'
	parsed_sha256 := parse_goal_task_acceptance_request('{"attempt":"1","candidate_sha":"${'b'.repeat(64)}","decision":"accept"}') or {
		panic(err)
	}
	assert parsed_sha256.candidate_sha == 'b'.repeat(64)

	for raw in [
		'{}',
		'{"attempt":"1","candidate_sha":"${candidate}","decision":"reject"}',
		'{"attempt":1,"candidate_sha":"${candidate}","decision":"accept"}',
		'{"attempt":"1","candidate_sha":"${candidate}","decision":"accept","extra":"x"}',
		'{"attempt":"1","attempt":"2","candidate_sha":"${candidate}","decision":"accept"}',
		'{"attempt":"0","candidate_sha":"${candidate}","decision":"accept"}',
		'{"attempt":"1","candidate_sha":"short","decision":"accept"}',
	] {
		if _ := parse_goal_task_acceptance_request(raw) {
			assert false, 'invalid acceptance request was accepted: ${raw}'
		}
	}
}

fn test_goal_task_acceptance_migration_is_idempotent() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-acceptance-migration-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'store.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	assert store.db.q_int('SELECT COUNT(*) FROM schema_migrations WHERE version = 45') or {
		panic(err)
	} == 1
	migrate_goal_task_acceptances(mut store.db) or { panic(err) }
	assert store.db.q_int('SELECT COUNT(*) FROM schema_migrations WHERE version = 45') or {
		panic(err)
	} == 1
	assert store.db.q_int("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'goal_task_acceptances'") or {
		panic(err)
	} == 1
}
