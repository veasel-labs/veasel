module main

import os
import rand

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
	store.close() or { panic(err) }

	store = open_store(path) or { panic(err) }
	seeded := store.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert seeded.status == 'pending'
	assert seeded.attempt_count == 0
	store.db.exec('DELETE FROM schema_migrations WHERE version = 36') or { panic(err) }
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
	store.complete_goal_task_attempt(goal.id, 'first', first.attempt_count, .succeeded) or { panic(err) }
	second := store.claim_goal_task(goal.id, 'second') or { panic(err) }
	store.complete_goal_task_attempt(goal.id, 'second', second.attempt_count, .failed) or { panic(err) }
	retry := store.claim_goal_task(goal.id, 'second') or { panic(err) }
	assert retry.attempt_count == 2
	store.complete_goal_task_attempt(goal.id, 'second', retry.attempt_count, .failed) or { panic(err) }
	final := store.goal_task_state(goal.id, 'second') or { panic(err) }
	assert final.status == 'failed'
	assert final.attempt_count == 2
	assert final.attempts.map(it.status) == ['failed', 'failed']
	total_attempts := store.db.exec_param('SELECT COUNT(*) FROM goal_task_attempts WHERE goal_id = ?', goal.id) or { panic(err) }
	assert total_attempts[0].val(0).int() == 3
	store.claim_goal_task(goal.id, 'second') or {
		assert err.msg().contains('attempt budget')
		return
	}
	assert false, 'claim exceeded goal attempt budget'
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
	store.complete_goal_task_attempt(goal.id, 'prepare', claimed.attempt_count, .succeeded) or {
		assert err.msg().contains('not running')
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
	return GoalAdmission{
		schema_version: 1
		id:             'goal-task-test'
		title:          'Test durable goal task state'
		budget:         GoalBudget{ max_attempts: 2, wall_seconds: 60, provider_turns: 4 }
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
