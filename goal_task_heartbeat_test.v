module main

import os
import rand
import time
import uuid

fn heartbeat_goal_admission(id string) GoalAdmission {
	return GoalAdmission{
		schema_version: 1
		id:             id
		title:          'Heartbeat test goal'
		budget:         GoalBudget{ max_attempts: 2, wall_seconds: 300, provider_turns: 4 }
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

fn test_goal_task_lease_heartbeat_is_linked_only_and_joins_without_interval_wait() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-task-heartbeat-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	goal := heartbeat_goal_admission('goal-task-heartbeat')
	_ = store.admit_goal(goal) or { panic(err) }
	session := store.create_session(SessionInput{ title: 'heartbeat', directory: root }) or {
		panic(err)
	}
	claim := store.claim_goal_task_for_session(goal.id, 'prepare', session.id) or { panic(err) }
	ordinary_operation := store.create_session_operation(session.id, uuid.new_v4().str()) or {
		panic(err)
	}
	ordinary_binding := store.linked_running_goal_task_lease(ordinary_operation.id) or { panic(err) }
	assert !ordinary_binding.linked
	linked_binding := store.linked_running_goal_task_lease(claim.session_operation_id) or {
		panic('linked running attempt was not discovered')
	}
	assert linked_binding.linked
	binding := linked_binding.binding
	assert binding.fencing_token == claim.fencing_token
	assert binding.generation == claim.lease_generation
	mut app := new_app(store, os.join_path(root, 'plugins'))
	defer { app.close() }
	heartbeat := app.start_goal_task_lease_heartbeat_with_timing(claim.session_operation_id,
		fn () {}, 10 * time.millisecond, 90) or { panic(err) }
	assert heartbeat.active
	mut initial_renewed_state := store.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert initial_renewed_state.attempts[0].lease_generation > claim.lease_generation
	initial_generation := initial_renewed_state.attempts[0].lease_generation
	// A short test cadence exercises the same renewal path without making the
	// focused test wait for the production 20-second interval.
	time.sleep(35 * time.millisecond)
	mut renewed_state := store.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert renewed_state.attempts[0].lease_generation > initial_generation
	started := time.now()
	app.stop_goal_task_lease_heartbeat(heartbeat)
	assert time.since(started) < time.second
}

fn test_goal_task_lease_renewal_does_not_resurrect_expired_fence() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-task-heartbeat-expired-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	goal := heartbeat_goal_admission('goal-task-heartbeat-expired')
	_ = store.admit_goal(goal) or { panic(err) }
	session := store.create_session(SessionInput{ title: 'heartbeat expiry', directory: root }) or {
		panic(err)
	}
	claim := store.claim_goal_task_for_session(goal.id, 'prepare', session.id) or { panic(err) }
	store.db.exec_param_many("UPDATE goal_task_attempts SET lease_expires_at = '2000-01-01T00:00:00Z' WHERE goal_id = ? AND task_id = ? AND attempt = 1", [
		goal.id,
		'prepare',
	]) or { panic(err) }
	mut rejected := false
	store.renew_goal_task_attempt_lease(goal.id, 'prepare', 1, claim.fencing_token,
		claim.lease_generation, 90) or {
		assert err.msg() == 'goal task lease has expired'
		rejected = true
		GoalTaskLease{}
	}
	assert rejected
	state := store.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert state.status == 'running'
	assert state.attempts[0].lease_generation == claim.lease_generation
	mut initial_rejected := false
	store.validate_goal_task_attempt_lease(GoalTaskLeaseBinding{
		goal_id:       goal.id
		task_id:       'prepare'
		attempt:       1
		fencing_token: claim.fencing_token
		generation:    claim.lease_generation
	}) or {
		assert err.msg() == 'goal task lease has expired'
		initial_rejected = true
	}
	assert initial_rejected
	store.expire_goal_task_attempt_lease(goal.id, 'prepare', 1, claim.fencing_token,
		claim.lease_generation) or { panic(err) }
	expired := store.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert expired.status == 'uncertain'
	store.linked_running_goal_task_lease(claim.session_operation_id) or {
		assert err.msg().contains('non-running')
		return
	}
	assert false, 'uncertain linked attempt was treated as unlinked'
}

fn test_goal_task_reconcile_uses_current_fence_after_renewal() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-task-reconcile-fence-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	goal := heartbeat_goal_admission('goal-task-reconcile-fence')
	_ = store.admit_goal(goal) or { panic(err) }
	session := store.create_session(SessionInput{ title: 'reconcile fence', directory: root }) or {
		panic(err)
	}
	claim := store.claim_goal_task_for_session(goal.id, 'prepare', session.id) or { panic(err) }
	renewed := store.renew_goal_task_attempt_lease(goal.id, 'prepare', 1, claim.fencing_token,
		claim.lease_generation, 90) or { panic(err) }
	store.reconcile_goal_task_operation(claim.session_operation_id, .succeeded) or {
		panic(err)
	}
	state := store.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert state.status == 'verifying'
	assert state.attempts[0].lease_generation == renewed.generation
	operation := store.get_session_operation(session.id, claim.session_operation_id) or {
		panic(err)
	}
	assert operation.status == 'completed'
}
