module main

import os
import json2
import rand
import time

fn test_goal_task_projection_is_stable_topological_order() {
	goal := GoalAdmission{
		id:    'graph'
		tasks: [
			GoalTask{
				id:         'z-final'
				title:      'Final task'
				repository: 'owner/repo'
				base_sha:   'a'.repeat(40)
				paths:      ['src']
				depends_on: ['m-middle', 'a-start']
				recipe:     'feature'
				runner:     'local-v'
				verifier:   'review'
			},
			GoalTask{
				id:         'm-middle'
				title:      'Middle task'
				repository: 'owner/repo'
				base_sha:   'a'.repeat(40)
				paths:      ['src']
				depends_on: ['a-start']
				recipe:     'feature'
				runner:     'local-v'
				verifier:   'review'
			},
			GoalTask{
				id:         'b-independent'
				title:      'Independent task'
				repository: 'owner/repo'
				base_sha:   'a'.repeat(40)
				paths:      ['docs']
				recipe:     'research'
				runner:     'local-v'
				verifier:   'review'
			},
			GoalTask{
				id:         'a-start'
				title:      'Start task'
				repository: 'owner/repo'
				base_sha:   'a'.repeat(40)
				paths:      ['src']
				recipe:     'feature'
				runner:     'local-v'
				verifier:   'review'
			},
		]
	}

	first := project_goal_task_graph(goal) or { panic(err) }
	second := project_goal_task_graph(goal) or { panic(err) }
	assert first.status == 'admitted'
	assert first.tasks.map(it.id) == ['b-independent', 'a-start', 'm-middle', 'z-final']
	assert first.tasks.map(it.status) == ['pending', 'pending', 'pending', 'pending']
	assert first.tasks[3].depends_on == ['m-middle', 'a-start']
	assert first.tasks.map(it.id) == second.tasks.map(it.id)
	encoded := json2.encode(first)
	assert !encoded.contains('policy_ceiling')
	assert !encoded.contains('permissions')
}

fn test_goal_task_projection_rejects_cycles_and_preserves_large_admitted_graphs() {
	cycle := GoalAdmission{
		id:    'cycle'
		tasks: [
			GoalTask{
				id:         'a'
				title:      'A'
				repository: 'owner/repo'
				base_sha:   'a'.repeat(40)
				paths:      ['src']
				depends_on: ['b']
			},
			GoalTask{
				id:         'b'
				title:      'B'
				repository: 'owner/repo'
				base_sha:   'a'.repeat(40)
				paths:      ['src']
				depends_on: ['a']
			},
		]
	}
	mut cycle_rejected := false
	project_goal_task_graph(cycle) or {
		cycle_rejected = true
		GoalTasksProjection{}
	}
	assert cycle_rejected

	mut large_tasks := []GoalTask{cap: 300}
	for i in 0 .. 300 {
		large_tasks << GoalTask{
			id:         'task-${i:03}'
			title:      'Task ${i}'
			repository: 'owner/repo'
			base_sha:   'a'.repeat(40)
			paths:      ['src']
			recipe:     'feature'
			runner:     'local-v'
			verifier:   'review'
		}
	}
	large_graph := GoalAdmission{
		id:    'large-graph'
		tasks: large_tasks
	}
	large_projection := project_goal_task_graph(large_graph) or { panic(err) }
	assert large_projection.tasks.len == 300
	assert large_projection.tasks.first().id == 'task-000'
	assert large_projection.tasks.last().id == 'task-299'
}

fn test_goal_task_state_is_seeded_idempotently_and_recovery_never_replays_running_attempts() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-task-state-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'veasel.sqlite3')
	goal := goal_task_test_admission()
	mut store := open_store(path) or { panic(err) }
	_ = store.admit_goal(goal) or { panic(err) }
	store.db.exec('DROP TABLE goal_task_attempts') or { panic(err) }
	store.db.exec('DROP TABLE goal_task_states') or { panic(err) }
	store.db.exec('DELETE FROM schema_migrations WHERE version = 36') or { panic(err) }
	store.db.exec('DELETE FROM schema_migrations WHERE version = 37') or { panic(err) }
	store.db.exec('DELETE FROM schema_migrations WHERE version = 38') or { panic(err) }
	store.db.exec('DELETE FROM schema_migrations WHERE version = 39') or { panic(err) }
	store.db.exec('DELETE FROM schema_migrations WHERE version = 40') or { panic(err) }
	store.db.exec('DELETE FROM schema_migrations WHERE version = 41') or { panic(err) }
	store.close() or { panic(err) }

	store = open_store(path) or { panic(err) }
	seeded := store.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert seeded.status == 'pending'
	assert seeded.attempt_count == 0
	for version in [36, 37, 38, 39, 40, 41] {
		store.db.exec_param_many('DELETE FROM schema_migrations WHERE version = ?', [version.str()]) or {
			panic(err)
		}
	}
	store.close() or { panic(err) }
	store = open_store(path) or { panic(err) }
	reseeded := store.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert reseeded.status == 'pending'
	assert reseeded.attempt_count == 0
	claimed := store.claim_goal_task(goal.id, 'prepare') or { panic(err) }
	assert claimed.status == 'running'
	assert claimed.attempt_count == 1
	assert claimed.attempts.len == 1
	assert claimed.attempts[0].status == 'running'
	mut second_connection := open_store(path) or { panic(err) }
	live := second_connection.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert live.status == 'running'
	assert live.attempts[0].status == 'running'
	second_connection.close() or { panic(err) }
	mut previous_owner := goal_task_test_long_lived_process()
	previous_owner.run()
	defer {
		if previous_owner.status == .running {
			previous_owner.signal_kill()
		}
		previous_owner.wait()
	}
	previous_pid := previous_owner.pid
	previous_identity := goal_task_owner_status(previous_pid)
	assert previous_identity.alive
	assert previous_identity.identity != ''
	previous_owner.signal_kill()
	previous_owner.wait()
	_ = store.db.exec_param_many('UPDATE goal_task_states SET owner_pid = ?, owner_start_id = ? WHERE goal_id = ?', [
		previous_pid.str(),
		previous_identity.identity,
		goal.id,
	]) or { panic(err) }
	_ = store.db.exec_param_many('UPDATE goal_task_attempts SET owner_pid = ?, owner_start_id = ? WHERE goal_id = ?', [
		previous_pid.str(),
		previous_identity.identity,
		goal.id,
	]) or { panic(err) }
	store.close() or { panic(err) }

	store = open_store(path) or { panic(err) }
	recovered := store.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert recovered.status == 'uncertain'
	assert recovered.attempts[0].status == 'uncertain'
	assert recovered.attempt_count == 1
	assert recovered.attempts.len == 1
	store.close() or { panic(err) }

	store = open_store(path) or { panic(err) }
	defer { store.close() or {} }
	second_reopen := store.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert second_reopen.status == recovered.status
	if recovered.status == 'uncertain' {
		store.claim_goal_task(goal.id, 'prepare') or {
			assert err.msg().contains('not claimable')
			return
		}
		assert false, 'recovery replayed an ambiguous attempt'
	}
}

fn goal_task_test_long_lived_process() &os.Process {
	$if windows {
		mut process := os.new_process(goal_task_test_cmd_executable())
		process.set_args(['/c', 'for /L %i in (1,1,200000000) do @rem veasel-goal-task-test-spin'])
		return process
	} $else {
		mut process := os.new_process('/bin/sleep')
		process.set_args(['30'])
		return process
	}
}

fn goal_task_test_cmd_executable() string {
	comspec := os.getenv('COMSPEC').trim_space()
	if comspec != '' {
		return comspec
	}
	return os.find_abs_path_of_executable('cmd.exe') or {
		panic('cmd.exe is required for the Windows goal task recovery test')
	}
}

fn test_goal_task_claim_gates_dependencies_and_enforces_attempt_budget() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-task-budget-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	goal := GoalAdmission{
		...goal_task_test_admission()
		id:     'dependency-budget'
		budget: GoalBudget{ max_attempts: 3, wall_seconds: 300, provider_turns: 4 }
		tasks:  [
			GoalTask{
				id:         'first'
				title:      'First'
				repository: 'veasel-labs/veasel'
				base_sha:   'e4b1a73e1573293d01e7f0b821a9c61161f165f3'
				paths:      ['docs']
				recipe:     'feature'
				runner:     'local-v'
				verifier:   'independent-review'
			},
			GoalTask{
				id:         'second'
				title:      'Second'
				repository: 'veasel-labs/veasel'
				base_sha:   'e4b1a73e1573293d01e7f0b821a9c61161f165f3'
				paths:      ['docs']
				depends_on: ['first']
				recipe:     'feature'
				runner:     'local-v'
				verifier:   'independent-review'
			},
		]
	}
	_ = store.admit_goal(goal) or { panic(err) }
	store.claim_goal_task(goal.id, 'second') or { assert err.msg().contains('dependencies') }
	first := store.claim_goal_task(goal.id, 'first') or { panic(err) }
	store.complete_goal_task_attempt(goal.id, 'first', first.attempt_count, .succeeded) or {
		assert err.msg().contains('independent verification receipt')
	}
	store.complete_goal_task_attempt(goal.id, 'first', first.attempt_count, .failed) or { panic(err) }
	retry := store.claim_goal_task(goal.id, 'first') or { panic(err) }
	assert retry.attempt_count == 2
	store.complete_goal_task_attempt(goal.id, 'first', retry.attempt_count, .failed) or { panic(err) }
	third := store.claim_goal_task(goal.id, 'first') or { panic(err) }
	store.complete_goal_task_attempt(goal.id, 'first', third.attempt_count, .failed) or { panic(err) }
	final := store.goal_task_state(goal.id, 'first') or { panic(err) }
	assert final.status == 'failed'
	assert final.attempt_count == 3
	assert final.attempts.map(it.status) == ['failed', 'failed', 'failed']
	total_attempts := store.db.exec_param('SELECT COUNT(*) FROM goal_task_attempts WHERE goal_id = ?', goal.id) or { panic(err) }
	assert total_attempts[0].val(0).int() == 3
	store.claim_goal_task(goal.id, 'second') or {
		assert err.msg().contains('dependencies')
		return
	}
	assert false, 'unverified completion must not satisfy task dependencies'
	store.claim_goal_task(goal.id, 'first') or {
		assert err.msg().contains('attempt budget')
		return
	}
	assert false, 'claim exceeded goal attempt budget'
}

fn test_linked_goal_task_attempt_uses_fencing_and_durable_session_operation() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-task-operation-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	goal := goal_task_test_admission()
	_ = store.admit_goal(goal) or { panic(err) }
	store.claim_goal_task_for_session(goal.id, 'prepare', 'missing-session') or {
		assert err.msg().contains('session not found')
	}
	assert (store.goal_task_state(goal.id, 'prepare') or { panic(err) }).status == 'pending'
	session := store.create_session(SessionInput{ title: 'linked task', directory: root }) or {
		panic(err)
	}
	claim := store.claim_goal_task_for_session(goal.id, 'prepare', session.id) or { panic(err) }
	assert claim.state.status == 'running'
	assert claim.state.attempt_count == 1
	assert claim.session_operation_id.len > 0
	assert claim.fencing_token.len > 0
	operation := store.get_session_operation(session.id, claim.session_operation_id) or { panic(err) }
	assert operation.status == 'running'
	links := store.db.exec_param_many('SELECT session_id, session_operation_id, fencing_token FROM goal_task_attempts WHERE goal_id = ? AND task_id = ? AND attempt = 1', [
		goal.id,
		'prepare',
	]) or { panic(err) }
	assert links.len == 1
	assert links[0].val(0) == session.id
	assert links[0].val(1) == claim.session_operation_id
	assert links[0].val(2) == claim.fencing_token
	mut second_connection := open_store(store.path) or { panic(err) }
	live_state := second_connection.goal_task_state(goal.id, 'prepare') or { panic(err) }
	live_operation := second_connection.get_session_operation(session.id,
		claim.session_operation_id) or { panic(err) }
	assert live_state.status == 'running'
	assert live_state.attempts[0].status == 'running'
	assert live_operation.status == 'running'
	second_connection.close() or { panic(err) }
	store.complete_linked_goal_task_attempt(goal.id, 'prepare', 1, claim.fencing_token,
		.failed) or { panic(err) }
	failed_operation := store.get_session_operation(session.id, claim.session_operation_id) or {
		panic(err)
	}
	assert failed_operation.status == 'failed'
	retry := store.claim_goal_task_for_session(goal.id, 'prepare', session.id) or { panic(err) }
	assert retry.state.attempt_count == 2
	assert retry.session_operation_id != claim.session_operation_id
	assert retry.fencing_token != claim.fencing_token
	store.complete_linked_goal_task_attempt(goal.id, 'prepare', 2, claim.fencing_token,
		.succeeded) or {
		assert err.msg().contains('not running')
	}
	current := store.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert current.status == 'running'
	assert current.attempts[1].status == 'running'
	current_operation := store.get_session_operation(session.id, retry.session_operation_id) or {
		panic(err)
	}
	assert current_operation.status == 'running'
	store.complete_linked_goal_task_attempt(goal.id, 'prepare', 2, retry.fencing_token,
		.succeeded) or { assert err.msg().contains('independent verification receipt') }
	current_after_success_bypass := store.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert current_after_success_bypass.status == 'running'
	assert current_after_success_bypass.attempts[1].status == 'running'
	store.reconcile_goal_task_operation(retry.session_operation_id, .succeeded) or { panic(err) }
	completed_operation := store.get_session_operation(session.id, retry.session_operation_id) or {
		panic(err)
	}
	assert completed_operation.status == 'completed'
	assert (store.goal_task_state(goal.id, 'prepare') or { panic(err) }).status == 'verifying'
	started := store.db.exec_param_many("SELECT COUNT(*) FROM events WHERE session_id = ? AND type = 'goal.task_attempt_started'", [
		session.id,
	]) or { panic(err) }
	completed := store.db.exec_param_many("SELECT COUNT(*) FROM events WHERE session_id = ? AND type = 'goal.task_attempt_completed'", [
		session.id,
	]) or { panic(err) }
	assert started[0].val(0).int() == 2
	assert completed[0].val(0).int() == 2
	started_payloads := store.db.exec_param_many("SELECT data FROM events WHERE session_id = ? AND type = 'goal.task_attempt_started' ORDER BY id", [
		session.id,
	]) or { panic(err) }
	started_payload := json2.decode[GoalTaskEventData](started_payloads[0].val(0)) or {
		panic(err)
	}
	assert started_payload.goal_id == goal.id
	assert started_payload.task_id == 'prepare'
	assert started_payload.attempt == 1
	assert started_payload.operation_id == claim.session_operation_id
	completed_payloads := store.db.exec_param_many("SELECT data FROM events WHERE session_id = ? AND type = 'goal.task_attempt_completed' ORDER BY id", [
		session.id,
	]) or { panic(err) }
	completed_payload := json2.decode[GoalTaskEventData](completed_payloads[0].val(0)) or {
		panic(err)
	}
	assert completed_payload.goal_id == goal.id
	assert completed_payload.task_id == 'prepare'
	assert completed_payload.attempt == 1
	assert completed_payload.operation_id == claim.session_operation_id
	assert completed_payload.status == 'failed'
	assert completed_payload.outcome == 'failed'
	session_turn_events := store.db.exec_param_many("SELECT COUNT(*) FROM events WHERE session_id = ? AND type IN ('session.turn_started', 'session.turn_completed')", [
		session.id,
	]) or { panic(err) }
	assert session_turn_events[0].val(0).int() == 0
}

fn test_successful_linked_operation_enters_verifying_until_independent_receipt() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-task-verifying-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'veasel.sqlite3')
	goal := goal_task_test_admission()
	mut store := open_store(path) or { panic(err) }
	_ = store.admit_goal(goal) or { panic(err) }
	session := store.create_session(SessionInput{ title: 'verifying task', directory: root }) or {
		panic(err)
	}
	claim := store.claim_goal_task_for_session(goal.id, 'prepare', session.id) or { panic(err) }
	store.reconcile_goal_task_operation(claim.session_operation_id, .succeeded) or { panic(err) }
	state := store.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert state.status == 'verifying'
	assert state.attempts[0].status == 'verifying'
	operation := store.get_session_operation(session.id, claim.session_operation_id) or {
		panic(err)
	}
	assert operation.status == 'completed'
	assert operation.outcome == 'completed'
	// Verification is not a dependency completion and the reconciliation is
	// once-only; neither path may silently promote the task to succeeded.
	mut dependency_blocked := false
	store.claim_goal_task(goal.id, 'prepare') or {
		dependency_blocked = true
		assert err.msg().contains('dependencies') || err.msg().contains('claimable')
		GoalTaskProjectionState{}
	}
	assert dependency_blocked
	store.reconcile_goal_task_operation(claim.session_operation_id, .succeeded) or {
		panic(err)
	}
	assert (store.goal_task_state(goal.id, 'prepare') or { panic(err) }).status == 'verifying'
	store.close() or { panic(err) }
	mut recovered := open_store(path) or { panic(err) }
	defer { recovered.close() or {} }
	recovered_state := recovered.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert recovered_state.status == 'verifying'
	assert recovered_state.attempts[0].status == 'verifying'
}

fn test_recovery_promotes_completed_session_operation_only_to_verifying() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-task-verifying-recovery-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'veasel.sqlite3')
	goal := goal_task_test_admission()
	mut store := open_store(path) or { panic(err) }
	_ = store.admit_goal(goal) or { panic(err) }
	session := store.create_session(SessionInput{ title: 'verifying recovery', directory: root }) or {
		panic(err)
	}
	claim := store.claim_goal_task_for_session(goal.id, 'prepare', session.id) or { panic(err) }
	_ = store.db.exec_param_many("UPDATE session_operations SET status = 'completed', outcome = 'completed' WHERE session_id = ? AND id = ?", [
		session.id,
		claim.session_operation_id,
	]) or { panic(err) }
	_ = store.db.exec_param_many("UPDATE goal_task_states SET owner_start_id = '' WHERE goal_id = ? AND task_id = ?", [
		goal.id,
		'prepare',
	]) or { panic(err) }
	_ = store.db.exec_param_many("UPDATE goal_task_attempts SET owner_start_id = '' WHERE goal_id = ? AND task_id = ? AND attempt = ?", [
		goal.id,
		'prepare',
		'1',
	]) or { panic(err) }
	store.close() or { panic(err) }
	mut recovered := open_store(path) or { panic(err) }
	defer { recovered.close() or {} }
	state := recovered.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert state.status == 'verifying'
	assert state.attempts[0].status == 'verifying'
	operation := recovered.get_session_operation(session.id, claim.session_operation_id) or {
		panic(err)
	}
	assert operation.status == 'completed'
	events := recovered.db.exec_param_many("SELECT COUNT(*) FROM events WHERE session_id = ? AND type = 'goal.task_attempt_verifying'", [
		session.id,
	]) or { panic(err) }
	assert events[0].val(0).int() == 1
}

fn test_recovery_promotes_completed_with_denials_operation_to_verifying() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-task-denials-recovery-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'veasel.sqlite3')
	goal := goal_task_test_admission()
	mut store := open_store(path) or { panic(err) }
	_ = store.admit_goal(goal) or { panic(err) }
	session := store.create_session(SessionInput{ title: 'denied effects recovery', directory: root }) or {
		panic(err)
	}
	claim := store.claim_goal_task_for_session(goal.id, 'prepare', session.id) or { panic(err) }
	_ = store.db.exec_param_many("UPDATE session_operations SET status = 'completed', outcome = 'completed_with_denials' WHERE session_id = ? AND id = ?", [
		session.id,
		claim.session_operation_id,
	]) or { panic(err) }
	_ = store.db.exec_param_many("UPDATE goal_task_states SET owner_start_id = '' WHERE goal_id = ? AND task_id = ?", [
		goal.id,
		'prepare',
	]) or { panic(err) }
	_ = store.db.exec_param_many("UPDATE goal_task_attempts SET owner_start_id = '' WHERE goal_id = ? AND task_id = ? AND attempt = ?", [
		goal.id,
		'prepare',
		'1',
	]) or { panic(err) }
	store.close() or { panic(err) }
	mut recovered := open_store(path) or { panic(err) }
	defer { recovered.close() or {} }
	state := recovered.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert state.status == 'verifying'
	assert state.attempts[0].status == 'verifying'
	operation := recovered.get_session_operation(session.id, claim.session_operation_id) or {
		panic(err)
	}
	assert operation.status == 'completed'
	assert operation.outcome == 'completed_with_denials'
}

fn test_linked_goal_task_claim_recovery_marks_operation_uncertain_without_replay() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-task-operation-recovery-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'veasel.sqlite3')
	goal := goal_task_test_admission()
	mut store := open_store(path) or { panic(err) }
	_ = store.admit_goal(goal) or { panic(err) }
	session := store.create_session(SessionInput{
		title:     'linked task recovery'
		directory: root
	}) or { panic(err) }
	claim := store.claim_goal_task_for_session(goal.id, 'prepare', session.id) or { panic(err) }
	_ = store.db.exec_param_many("UPDATE goal_task_states SET owner_start_id = '' WHERE goal_id = ? AND task_id = ?", [
		goal.id,
		'prepare',
	]) or { panic(err) }
	_ = store.db.exec_param_many("UPDATE goal_task_attempts SET owner_start_id = '' WHERE goal_id = ? AND task_id = ?", [
		goal.id,
		'prepare',
	]) or { panic(err) }
	store.close() or { panic(err) }
	mut recovered_store := open_store(path) or { panic(err) }
	defer { recovered_store.close() or {} }
	state := recovered_store.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert state.status == 'uncertain'
	assert state.attempts[0].status == 'uncertain'
	operation := recovered_store.get_session_operation(session.id, claim.session_operation_id) or {
		panic(err)
	}
	assert operation.status == 'uncertain'
	completions := recovered_store.db.exec_param_many("SELECT COUNT(*) FROM events WHERE session_id = ? AND type = 'goal.task_attempt_completed'", [
		session.id,
	]) or { panic(err) }
	assert completions[0].val(0).int() == 1
	recovered_store.claim_goal_task_for_session(goal.id, 'prepare', session.id) or {
		assert err.msg().contains('not claimable')
		return
	}
	assert false, 'recovery replayed a linked ambiguous attempt'
}

fn test_linked_queued_goal_dispatch_recovery_marks_operation_uncertain_without_replay() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-task-queued-recovery-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'veasel.sqlite3')
	goal := goal_task_test_admission()
	mut store := open_store(path) or { panic(err) }
	_ = store.admit_goal(goal) or { panic(err) }
	session := store.create_session(SessionInput{
		title:     'queued linked task recovery'
		directory: root
	}) or { panic(err) }
	claim := store.claim_goal_task_for_dispatch(goal.id, 'prepare') or { panic(err) }
	record_ready_goal_dispatch_test_workspace(mut store, goal, 'prepare', 1, root)
	operation_id := store.attach_goal_task_attempt_session(goal.id, 'prepare', 1,
		claim.fencing_token, session.id, '{"content":"resume must not run"}') or { panic(err) }
	queued := store.list_queued_session_operations() or { panic(err) }
	assert queued.len == 1
	assert queued[0].id == operation_id
	_ = store.db.exec_param_many("UPDATE goal_task_states SET owner_start_id = '' WHERE goal_id = ? AND task_id = ?", [
		goal.id,
		'prepare',
	]) or { panic(err) }
	_ = store.db.exec_param_many("UPDATE goal_task_attempts SET owner_start_id = '' WHERE goal_id = ? AND task_id = ?", [
		goal.id,
		'prepare',
	]) or { panic(err) }
	store.close() or { panic(err) }
	mut recovered_store := open_store(path) or { panic(err) }
	defer { recovered_store.close() or {} }
	state := recovered_store.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert state.status == 'uncertain'
	assert state.attempts[0].status == 'uncertain'
	operation := recovered_store.get_session_operation(session.id, operation_id) or { panic(err) }
	assert operation.status == 'uncertain'
	recovered_queue := recovered_store.list_queued_session_operations() or { panic(err) }
	assert recovered_queue.len == 0
}

fn test_rejected_queued_goal_operation_reconciles_attempt_for_retry() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-task-queued-reject-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	goal := goal_task_test_admission()
	_ = store.admit_goal(goal) or { panic(err) }
	session := store.create_session(SessionInput{
		title:     'queued goal rejection'
		directory: root
	}) or { panic(err) }
	claim := store.claim_goal_task_for_dispatch(goal.id, 'prepare') or { panic(err) }
	record_ready_goal_dispatch_test_workspace(mut store, goal, 'prepare', 1, root)
	operation_id := store.attach_goal_task_attempt_session(goal.id, 'prepare', 1,
		claim.fencing_token, session.id, '{"content":"must be rejected"}') or { panic(err) }
	store.reject_queued_session_operation(session.id, operation_id,
		'provider is unavailable') or { panic(err) }
	state := store.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert state.status == 'pending'
	assert state.attempts[0].status == 'failed'
	operation := store.get_session_operation(session.id, operation_id) or { panic(err) }
	assert operation.status == 'cancelled'
}

fn test_cancelled_queued_goal_operation_reconciles_as_uncertain() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-task-queued-cancel-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	goal := goal_task_test_admission()
	_ = store.admit_goal(goal) or { panic(err) }
	session := store.create_session(SessionInput{
		title:     'queued goal cancellation'
		directory: root
	}) or { panic(err) }
	claim := store.claim_goal_task_for_dispatch(goal.id, 'prepare') or { panic(err) }
	record_ready_goal_dispatch_test_workspace(mut store, goal, 'prepare', 1, root)
	operation_id := store.attach_goal_task_attempt_session(goal.id, 'prepare', 1,
		claim.fencing_token, session.id, '{"content":"must be cancelled"}') or { panic(err) }
	store.cancel_session_operation(session.id, operation_id) or { panic(err) }
	state := store.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert state.status == 'uncertain'
	assert state.attempts[0].status == 'uncertain'
	operation := store.get_session_operation(session.id, operation_id) or { panic(err) }
	assert operation.status == 'cancelled'
	workspace := store.db.exec_param_many('SELECT status FROM goal_task_attempt_workspaces WHERE goal_id = ? AND task_id = ? AND attempt = ?', [
		goal.id,
		'prepare',
		'1',
	]) or { panic(err) }
	assert workspace[0].val(0) == 'uncertain'
}

fn test_linked_goal_task_recovery_tolerates_deleted_session() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-task-deleted-session-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'veasel.sqlite3')
	goal := goal_task_test_admission()
	mut store := open_store(path) or { panic(err) }
	_ = store.admit_goal(goal) or { panic(err) }
	session := store.create_session(SessionInput{
		title:     'deleted task session'
		directory: root
	}) or { panic(err) }
	_ = store.claim_goal_task_for_session(goal.id, 'prepare', session.id) or { panic(err) }
	_ = store.db.exec_param_many("UPDATE goal_task_states SET owner_start_id = '' WHERE goal_id = ? AND task_id = ?", [
		goal.id,
		'prepare',
	]) or { panic(err) }
	_ = store.db.exec_param_many("UPDATE goal_task_attempts SET owner_start_id = '' WHERE goal_id = ? AND task_id = ?", [
		goal.id,
		'prepare',
	]) or { panic(err) }
	store.delete_session(session.id) or { panic(err) }
	store.close() or { panic(err) }
	mut recovered_store := open_store(path) or { panic(err) }
	defer { recovered_store.close() or {} }
	state := recovered_store.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert state.status == 'uncertain'
	assert state.attempts[0].status == 'uncertain'
}

fn test_linked_goal_task_verification_survives_deleted_session_without_acceptance() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-task-complete-deleted-session-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	goal := goal_task_test_admission()
	_ = store.admit_goal(goal) or { panic(err) }
	session := store.create_session(SessionInput{
		title:     'deleted task session completion'
		directory: root
	}) or { panic(err) }
	claim := store.claim_goal_task_for_session(goal.id, 'prepare', session.id) or { panic(err) }
	store.delete_session(session.id) or { panic(err) }
	store.complete_linked_goal_task_attempt(goal.id, 'prepare', 1, claim.fencing_token,
		.verifying) or { panic(err) }
	state := store.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert state.status == 'verifying'
	assert state.attempts[0].status == 'verifying'
	operations := store.db.exec_param_many('SELECT COUNT(*) FROM session_operations WHERE id = ?', [
		claim.session_operation_id,
	]) or { panic(err) }
	assert operations[0].val(0).int() == 0
}

fn test_linked_goal_task_completion_fails_closed_when_operation_is_missing() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-task-missing-operation-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	goal := goal_task_test_admission()
	_ = store.admit_goal(goal) or { panic(err) }
	session := store.create_session(SessionInput{
		title:     'missing operation completion'
		directory: root
	}) or { panic(err) }
	claim := store.claim_goal_task_for_session(goal.id, 'prepare', session.id) or { panic(err) }
	_ = store.db.exec_param_many('DELETE FROM session_operations WHERE session_id = ? AND id = ?', [
		session.id,
		claim.session_operation_id,
	]) or { panic(err) }
	store.complete_linked_goal_task_attempt(goal.id, 'prepare', 1, claim.fencing_token,
		.failed) or {
		assert err.msg().contains('session operation not found')
		state := store.goal_task_state(goal.id, 'prepare') or { panic(err) }
		assert state.status == 'running'
		assert state.attempts[0].status == 'running'
		return
	}
	assert false, 'completion must fail when the linked operation is missing'
}

fn test_dispatch_claim_has_fencing_before_session_link_and_is_fail_closed() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-dispatch-claim-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	goal := goal_task_test_admission()
	_ = store.admit_goal(goal) or { panic(err) }
	claim := store.claim_goal_task_for_dispatch(goal.id, 'prepare') or { panic(err) }
	assert claim.fencing_token.len > 0
	assert claim.session_operation_id == ''
	store.complete_linked_goal_task_attempt(goal.id, 'prepare', claim.state.attempt_count,
		claim.fencing_token, .uncertain) or { panic(err) }
	state := store.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert state.status == 'uncertain'
	assert state.attempts[0].status == 'uncertain'
}

fn test_goal_task_completion_rolls_back_when_state_row_is_not_running() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-task-state-mismatch-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	goal := goal_task_test_admission()
	_ = store.admit_goal(goal) or { panic(err) }
	claimed := store.claim_goal_task(goal.id, 'prepare') or { panic(err) }
	_ = store.db.exec_param_many("UPDATE goal_task_states SET status = 'pending' WHERE goal_id = ? AND task_id = ?", [
		goal.id,
		'prepare',
	]) or { panic(err) }
	store.complete_goal_task_attempt(goal.id, 'prepare', claimed.attempt_count, .failed) or {
		assert err.msg().contains('goal task is not running')
		attempts := store.db.exec_param_many('SELECT status FROM goal_task_attempts WHERE goal_id = ? AND task_id = ?', [
			goal.id,
			'prepare',
		]) or { panic(err) }
		assert attempts.len == 1
		assert attempts[0].val(0) == 'running'
		return
	}
	assert false, 'completion must fail when the state row is not running'
}

fn test_goal_task_recovery_classifies_legacy_pid_only_claim_as_uncertain() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-task-legacy-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'veasel.sqlite3')
	goal := goal_task_test_admission()
	mut store := open_store(path) or { panic(err) }
	_ = store.admit_goal(goal) or { panic(err) }
	_ = store.claim_goal_task(goal.id, 'prepare') or { panic(err) }
	_ = store.db.exec_param_many("UPDATE goal_task_states SET owner_start_id = '' WHERE goal_id = ?", [
		goal.id,
	]) or { panic(err) }
	_ = store.db.exec_param_many("UPDATE goal_task_attempts SET owner_start_id = '' WHERE goal_id = ?", [
		goal.id,
	]) or { panic(err) }
	store.close() or { panic(err) }

	store = open_store(path) or { panic(err) }
	defer { store.close() or {} }
	state := store.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert state.status == 'uncertain'
	assert state.attempts.map(it.status) == ['uncertain']
}

fn test_goal_task_recovery_detects_reused_pid_with_different_start_identity() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-task-pid-reuse-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'veasel.sqlite3')
	goal := goal_task_test_admission()
	mut store := open_store(path) or { panic(err) }
	_ = store.admit_goal(goal) or { panic(err) }
	_ = store.claim_goal_task(goal.id, 'prepare') or { panic(err) }
	_ = store.db.exec_param_many('UPDATE goal_task_states SET owner_start_id = ? WHERE goal_id = ?', [
		'stale-process-start',
		goal.id,
	]) or { panic(err) }
	_ = store.db.exec_param_many('UPDATE goal_task_attempts SET owner_start_id = ? WHERE goal_id = ?', [
		'stale-process-start',
		goal.id,
	]) or { panic(err) }
	store.close() or { panic(err) }

	store = open_store(path) or { panic(err) }
	defer { store.close() or {} }
	state := store.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert state.status == 'uncertain'
	assert state.attempts.map(it.status) == ['uncertain']
}

fn claim_goal_task_concurrently(path string, goal_id string, task_id string, start chan bool, result chan bool) {
	mut store := open_store(path) or {
		result <- false
		return
	}
	defer { store.close() or {} }
	_ = <-start
	if _ := store.claim_goal_task(goal_id, task_id) {
		result <- true
	} else {
		result <- false
	}
}

fn test_goal_task_claim_is_atomic_across_store_connections() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-task-claim-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'veasel.sqlite3')
	goal := goal_task_test_admission()
	mut store := open_store(path) or { panic(err) }
	_ = store.admit_goal(goal) or { panic(err) }
	store.close() or { panic(err) }
	start := chan bool{cap: 2}
	results := chan bool{cap: 2}
	spawn claim_goal_task_concurrently(path, goal.id, 'prepare', start, results)
	spawn claim_goal_task_concurrently(path, goal.id, 'prepare', start, results)
	start <- true
	start <- true
	one := <-results
	two := <-results
	assert (if one { 1 } else { 0 }) + (if two { 1 } else { 0 }) == 1
}

fn goal_task_test_admission() GoalAdmission {
	return goal_task_test_admission_with('goal-task-test', '', GoalBudget{
		max_attempts:   2
		wall_seconds:   60
		provider_turns: 4
	})
}

fn goal_task_test_admission_with(id string, deadline string, budget GoalBudget) GoalAdmission {
	return GoalAdmission{
		schema_version: 1
		id:             id
		title:          'Test durable goal task state'
		deadline:       deadline
		budget:         budget
		tasks:          [GoalTask{
			id:         'prepare'
			title:      'Prepare'
			repository: 'owner/repo'
			base_sha:   'a'.repeat(40)
			paths:      ['src']
			recipe:     'feature'
			runner:     'test-runner'
			verifier:   'test-verifier'
		}]
	}
}

fn record_ready_goal_dispatch_test_workspace(mut store Store, goal GoalAdmission, task_id string,
	attempt int, path string) {
	base_sha := goal.tasks.filter(it.id == task_id)[0].base_sha
	_ = store.db.exec_param_many("INSERT INTO goal_task_attempt_workspaces (goal_id, task_id, attempt, repository_root, worktree_path, base_sha, status) VALUES (?, ?, ?, ?, ?, ?, 'ready')", [
		goal.id,
		task_id,
		attempt.str(),
		path,
		path,
		base_sha,
	]) or { panic(err) }
}

fn test_goal_task_claim_deadline_lease_fence_and_reopen_are_durable() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-task-leases-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'veasel.sqlite3')
	goal := goal_task_test_admission_with('goal-task-leases',
		time.now().add(5 * time.minute).format_rfc3339(),
		GoalBudget{ max_attempts: 2, wall_seconds: 10, provider_turns: 2 })
	mut store := open_store(path) or { panic(err) }
	_ = store.admit_goal(goal) or { panic(err) }
	claim := store.claim_goal_task_for_dispatch(goal.id, 'prepare') or { panic(err) }
	assert claim.lease_generation == 1
	effective := time.parse_rfc3339(claim.effective_deadline) or { panic(err) }
	lease := time.parse_rfc3339(claim.lease_expires_at) or { panic(err) }
	now := time.now()
	assert effective.unix() <= now.add(11 * time.second).unix()
	assert lease.unix() <= effective.unix()
	assert lease.unix() >= now.unix()
	store.close() or { panic(err) }
	mut reopened := open_store(path) or { panic(err) }
	defer { reopened.close() or {} }
	persisted := reopened.goal_task_state(goal.id, 'prepare') or { panic(err) }
	persisted_attempt := persisted.attempts[0]
	assert persisted_attempt.effective_deadline == claim.effective_deadline
	assert persisted_attempt.lease_expires_at == claim.lease_expires_at
	assert persisted_attempt.lease_generation == 1
	renewed := reopened.renew_goal_task_attempt_lease(goal.id, 'prepare', 1, claim.fencing_token, 1, 3) or {
		panic(err)
	}
	assert renewed.generation == 2
	mut stale_generation_rejected := false
	reopened.renew_goal_task_attempt_lease(goal.id, 'prepare', 1, claim.fencing_token, 1, 3) or {
		assert err.msg().contains('stale')
		stale_generation_rejected = true
		GoalTaskLease{}
	}
	assert stale_generation_rejected
	mut stale_token_rejected := false
	reopened.renew_goal_task_attempt_lease(goal.id, 'prepare', 1, 'stale-token', 2, 3) or {
		assert err.msg().contains('stale')
		stale_token_rejected = true
		GoalTaskLease{}
	}
	assert stale_token_rejected
}

fn test_goal_task_expiry_is_fail_closed_and_never_retries() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-task-expiry-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'veasel.sqlite3')
	goal := goal_task_test_admission_with('goal-task-expiry',
		time.now().add(5 * time.minute).format_rfc3339(),
		GoalBudget{ max_attempts: 2, wall_seconds: 60, provider_turns: 4 })
	mut store := open_store(path) or { panic(err) }
	_ = store.admit_goal(goal) or { panic(err) }
	session := store.create_session(SessionInput{ title: 'lease expiry', directory: root }) or { panic(err) }
	claim := store.claim_goal_task_for_session(goal.id, 'prepare', session.id) or { panic(err) }
	record_ready_goal_dispatch_test_workspace(mut store, goal, 'prepare', 1, os.join_path(root, 'worktree'))
	mut premature_rejected := false
	store.expire_goal_task_attempt_lease(goal.id, 'prepare', 1, claim.fencing_token, claim.lease_generation) or {
		assert err.msg().contains('not expired')
		premature_rejected = true
	}
	assert premature_rejected
	// The canonical operation may have recorded a terminal result just before
	// lease expiry. Preserve it while fencing the attempt itself uncertain.
	store.db.exec_param_many("UPDATE session_operations SET status = 'completed', outcome = 'completed' WHERE session_id = ? AND id = ?", [
		session.id,
		claim.session_operation_id,
	]) or { panic(err) }
	store.db.exec_param_many("UPDATE goal_task_attempts SET lease_expires_at = '2000-01-01T00:00:00Z' WHERE goal_id = ? AND task_id = ? AND attempt = 1", [
		goal.id,
		'prepare',
	]) or { panic(err) }
	assert store.expire_goal_task_attempt_lease(goal.id, 'prepare', 1, claim.fencing_token, claim.lease_generation) or { panic(err) }
	state := store.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert state.status == 'uncertain'
	assert state.attempts[0].status == 'uncertain'
	workspace := store.db.exec_param_many('SELECT status FROM goal_task_attempt_workspaces WHERE goal_id = ? AND task_id = ? AND attempt = 1', [
		goal.id,
		'prepare',
	]) or { panic(err) }
	assert workspace[0].val(0) == 'uncertain'
	operation := store.get_session_operation(session.id, claim.session_operation_id) or { panic(err) }
	assert operation.status == 'completed'
	events := store.db.exec_param_many("SELECT COUNT(*) FROM events WHERE session_id = ? AND type = 'goal.task_attempt_completed'", [session.id]) or { panic(err) }
	assert events[0].val(0).int() == 1
	store.claim_goal_task(goal.id, 'prepare') or {
		assert err.msg().contains('dependencies') || err.msg().contains('claimable')
		return
	}
	assert false, 'uncertain attempt was retried'
}

fn test_goal_task_claim_rejects_expired_deadline() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-task-expired-deadline-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	goal := goal_task_test_admission_with('goal-task-expired-deadline',
		time.now().add(-1 * time.second).format_rfc3339(),
		GoalBudget{ max_attempts: 2, wall_seconds: 60, provider_turns: 4 })
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	_ = store.admit_goal(goal) or { panic(err) }
	store.claim_goal_task(goal.id, 'prepare') or {
		assert err.msg().contains('deadline')
		return
	}
	assert false, 'expired goal deadline was claimed'
}
