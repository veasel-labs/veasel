module main

import os
import rand

fn test_goal_task_verification_lease_is_fenced_durable_and_expires_closed() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-verification-lease-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'store.sqlite3')
	goal := goal_task_verification_test_admission()
	mut store := open_store(path) or { panic(err) }
	_ = store.admit_goal(goal) or { panic(err) }
	session := store.create_session(SessionInput{ title: 'verification', directory: root }) or { panic(err) }
	claim := store.claim_goal_task_for_session(goal.id, 'prepare', session.id) or { panic(err) }
	store.db.exec_param_many("INSERT INTO goal_task_attempt_workspaces (goal_id, task_id, attempt, repository_root, worktree_path, base_sha, status) VALUES (?, ?, 1, ?, ?, ?, 'ready')", [
		goal.id,
		'prepare',
		root,
		root,
		goal.tasks[0].base_sha,
	]) or { panic(err) }
	store.reconcile_goal_task_operation(claim.session_operation_id, .succeeded) or { panic(err) }
	lease := store.claim_goal_task_verification_lease(goal.id, 'prepare', 1, 30) or { panic(err) }
	assert lease.generation == 1
	assert lease.fencing_token != claim.fencing_token
	store.validate_goal_task_verification_lease(goal.id, 'prepare', 1, lease.fencing_token, lease.generation) or { panic(err) }
	store.db.exec_param_many("INSERT INTO goal_task_verifier_bindings (id, goal_id, task_id, attempt, fencing_token, lease_generation, repository, repository_root, worktree_path, base_sha, candidate_sha, verifier_id, verifier_version, status) VALUES ('lease-binding', ?, 'prepare', 1, ?, ?, 'owner/repo', ?, ?, ?, ?, 'review', 'builtin-review-v1', 'reserved')", [
		goal.id,
		lease.fencing_token,
		lease.generation.str(),
		root,
		root,
		goal.tasks[0].base_sha,
		'b'.repeat(40),
	]) or { panic(err) }
	renewed := store.renew_goal_task_verification_lease(goal.id, 'prepare', 1, lease.fencing_token, lease.generation, 30) or { panic(err) }
	assert renewed.generation == 2
	bound_fence := store.db.exec_param('SELECT fencing_token, lease_generation FROM goal_task_verifier_bindings WHERE id = ?', 'lease-binding') or {
		panic(err)
	}
	assert bound_fence[0].val(0) == renewed.fencing_token
	assert bound_fence[0].val(1).int() == renewed.generation
	store.renew_goal_task_verification_lease(goal.id, 'prepare', 1, lease.fencing_token, lease.generation, 30) or {
		assert err.msg().contains('stale')
		GoalTaskVerificationLease{}
	}
	store.db.exec_param_many("UPDATE goal_task_verification_leases SET lease_expires_at = '2000-01-01T00:00:00Z' WHERE goal_id = ? AND task_id = ? AND attempt = 1", [
		goal.id,
		'prepare',
	]) or { panic(err) }
	reclaimed := store.claim_goal_task_verification_lease(goal.id, 'prepare', 1, 30) or { panic(err) }
	assert reclaimed.verification_deadline == lease.verification_deadline
	reclaimed_fence := store.db.exec_param('SELECT fencing_token, lease_generation FROM goal_task_verifier_bindings WHERE id = ?', 'lease-binding') or {
		panic(err)
	}
	assert reclaimed_fence[0].val(0) == reclaimed.fencing_token
	assert reclaimed_fence[0].val(1).int() == reclaimed.generation
	if _ := store.bind_goal_task_verifier_run('lease-binding', 'late-old-reviewer-run',
		lease.fencing_token, lease.generation) {
		assert false, 'a caller holding the old binding fence must not bind a late run'
	}
	store.close() or { panic(err) }
	mut reopened := open_store(path) or { panic(err) }
	defer { reopened.close() or {} }
	reopened_state := reopened.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert reopened_state.status == 'verifying'
	reopened.validate_goal_task_verification_lease(goal.id, 'prepare', 1, reclaimed.fencing_token, reclaimed.generation) or { panic(err) }
	reopened.db.exec_param_many("UPDATE goal_task_verification_leases SET lease_expires_at = '2000-01-01T00:00:00Z' WHERE goal_id = ? AND task_id = ? AND attempt = 1", [
		goal.id,
		'prepare',
	]) or { panic(err) }
	assert reopened.expire_goal_task_verification_lease(goal.id, 'prepare', 1, reclaimed.fencing_token, reclaimed.generation) or { panic(err) }
	state := reopened.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert state.status == 'uncertain'
	assert state.attempts[0].status == 'uncertain'
	workspace := reopened.db.exec_param_many('SELECT status FROM goal_task_attempt_workspaces WHERE goal_id = ? AND task_id = ? AND attempt = 1', [
		goal.id,
		'prepare',
	]) or { panic(err) }
	assert workspace[0].val(0) == 'uncertain'
	events := reopened.db.exec_param_many("SELECT COUNT(*) FROM events WHERE session_id = ? AND type = 'goal.task_attempt_completed' AND data LIKE '%verification lease expired%'", [session.id]) or { panic(err) }
	assert events[0].val(0).int() == 1
}

fn test_goal_task_verification_lease_with_invalid_timestamps_recovers_closed_after_restart() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-verification-invalid-recovery-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'store.sqlite3')
	goal := goal_task_verification_test_admission()
	mut store := open_store(path) or { panic(err) }
	_ = store.admit_goal(goal) or { panic(err) }
	session := store.create_session(SessionInput{ title: 'verification recovery', directory: root }) or {
		panic(err)
	}
	claim := store.claim_goal_task_for_session(goal.id, 'prepare', session.id) or { panic(err) }
	store.db.exec_param_many("INSERT INTO goal_task_attempt_workspaces (goal_id, task_id, attempt, repository_root, worktree_path, base_sha, status) VALUES (?, ?, 1, ?, ?, ?, 'ready')", [
		goal.id,
		'prepare',
		root,
		root,
		goal.tasks[0].base_sha,
	]) or { panic(err) }
	store.reconcile_goal_task_operation(claim.session_operation_id, .succeeded) or { panic(err) }
	_ := store.claim_goal_task_verification_lease(goal.id, 'prepare', 1, 30) or { panic(err) }
	store.db.exec_param_many("UPDATE goal_task_verification_leases SET verification_deadline = 'invalid', lease_expires_at = 'invalid' WHERE goal_id = ? AND task_id = ? AND attempt = 1", [
		goal.id,
		'prepare',
	]) or { panic(err) }
	store.close() or { panic(err) }

	mut recovered := open_store(path) or { panic(err) }
	defer { recovered.close() or {} }
	state := recovered.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert state.status == 'uncertain'
	assert state.attempts[0].status == 'uncertain'
	workspace := recovered.db.exec_param_many('SELECT status FROM goal_task_attempt_workspaces WHERE goal_id = ? AND task_id = ? AND attempt = 1', [
		goal.id,
		'prepare',
	]) or { panic(err) }
	assert workspace[0].val(0) == 'uncertain'
	leases := recovered.db.exec_param_many('SELECT COUNT(*) FROM goal_task_verification_leases WHERE goal_id = ? AND task_id = ? AND attempt = 1', [
		goal.id,
		'prepare',
	]) or { panic(err) }
	assert leases[0].val(0).int() == 0
	events := recovered.db.exec_param_many("SELECT COUNT(*) FROM events WHERE session_id = ? AND type = 'goal.task_attempt_completed' AND data LIKE '%verification lease expired%'", [session.id]) or { panic(err) }
	assert events[0].val(0).int() == 1
}

fn test_goal_task_without_verification_lease_recovers_closed_after_restart() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-verification-no-lease-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'store.sqlite3')
	goal := goal_task_verification_test_admission()
	mut store := open_store(path) or { panic(err) }
	_ = store.admit_goal(goal) or { panic(err) }
	session := store.create_session(SessionInput{ title: 'verification no lease', directory: root }) or {
		panic(err)
	}
	claim := store.claim_goal_task_for_session(goal.id, 'prepare', session.id) or { panic(err) }
	store.db.exec_param_many("INSERT INTO goal_task_attempt_workspaces (goal_id, task_id, attempt, repository_root, worktree_path, base_sha, status) VALUES (?, ?, 1, ?, ?, ?, 'ready')", [
		goal.id,
		'prepare',
		root,
		root,
		goal.tasks[0].base_sha,
	]) or { panic(err) }
	store.reconcile_goal_task_operation(claim.session_operation_id, .succeeded) or { panic(err) }
	store.close() or { panic(err) }

	mut recovered := open_store(path) or { panic(err) }
	defer { recovered.close() or {} }
	state := recovered.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert state.status == 'uncertain'
	assert state.attempts[0].status == 'uncertain'
	workspace := recovered.db.exec_param_many('SELECT status FROM goal_task_attempt_workspaces WHERE goal_id = ? AND task_id = ? AND attempt = 1', [
		goal.id,
		'prepare',
	]) or { panic(err) }
	assert workspace[0].val(0) == 'uncertain'
	events := recovered.db.exec_param_many("SELECT COUNT(*) FROM events WHERE session_id = ? AND type = 'goal.task_attempt_completed' AND data LIKE '%verification lease expired%'", [session.id]) or { panic(err) }
	assert events[0].val(0).int() == 1
}

fn test_expired_bound_goal_reviewer_cannot_be_reclaimed_under_a_new_fence() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-verification-bound-reclaim-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	goal := goal_task_verification_test_admission()
	mut store := open_store(os.join_path(root, 'store.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	_ = store.admit_goal(goal) or { panic(err) }
	session := store.create_session(SessionInput{ title: 'bound reviewer', directory: root }) or { panic(err) }
	claim := store.claim_goal_task_for_session(goal.id, 'prepare', session.id) or { panic(err) }
	store.db.exec_param_many("INSERT INTO goal_task_attempt_workspaces (goal_id, task_id, attempt, repository_root, worktree_path, base_sha, status) VALUES (?, ?, 1, ?, ?, ?, 'ready')", [
		goal.id,
		'prepare',
		root,
		root,
		goal.tasks[0].base_sha,
	]) or { panic(err) }
	store.reconcile_goal_task_operation(claim.session_operation_id, .succeeded) or { panic(err) }
	lease := store.claim_goal_task_verification_lease(goal.id, 'prepare', 1, 30) or { panic(err) }
	store.db.exec_param_many("INSERT INTO goal_task_verifier_bindings (id, goal_id, task_id, attempt, fencing_token, lease_generation, repository, repository_root, worktree_path, base_sha, candidate_sha, verifier_id, verifier_version, reviewer_run_id, status) VALUES ('bound-binding', ?, 'prepare', 1, ?, ?, 'owner/repo', ?, ?, ?, ?, 'review', 'builtin-review-v1', 'old-reviewer-run', 'bound')", [
		goal.id,
		lease.fencing_token,
		lease.generation.str(),
		root,
		root,
		goal.tasks[0].base_sha,
		'b'.repeat(40),
	]) or { panic(err) }
	store.db.exec_param_many("UPDATE goal_task_verification_leases SET lease_expires_at = '2000-01-01T00:00:00Z' WHERE goal_id = ? AND task_id = ? AND attempt = 1", [
		goal.id,
		'prepare',
	]) or { panic(err) }
	if _ := store.claim_goal_task_verification_lease(goal.id, 'prepare', 1, 30) {
		assert false, 'expired bound reviewer runs must fail closed instead of changing fences'
	}
	current := store.db.exec_param_many('SELECT fencing_token, generation FROM goal_task_verification_leases WHERE goal_id = ? AND task_id = ? AND attempt = 1', [
		goal.id,
		'prepare',
	]) or {
		panic(err)
	}
	assert current[0].val(0) == lease.fencing_token
	assert current[0].val(1).int() == lease.generation
	assert store.expire_goal_task_verification_lease(goal.id, 'prepare', 1, lease.fencing_token,
		lease.generation) or { panic(err) }
	assert (store.goal_task_state(goal.id, 'prepare') or { panic(err) }).status == 'uncertain'
}

fn goal_task_verification_test_admission() GoalAdmission {
	return GoalAdmission{
		schema_version: 1
		id:             'goal-verification-lease-test'
		title:          'Verification lease test'
		budget:         GoalBudget{
			max_attempts:   2
			wall_seconds:   120
			provider_turns: 4
		}
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
