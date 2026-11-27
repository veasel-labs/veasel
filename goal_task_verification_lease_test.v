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
	goal := goal_task_verification_recovery_admission('goal-verification-no-lease', root)
	mut store := open_store(path) or { panic(err) }
	_ = store.admit_goal(goal) or { panic(err) }
	session := store.create_session(SessionInput{ title: 'verification no lease', directory: root }) or {
		panic(err)
	}
	workspace_path := os.join_path(os.dir(root), 'veasel-goal-task-worktree-${rand.ulid()}')
	os.mkdir_all(workspace_path) or { panic(err) }
	defer { os.rmdir_all(workspace_path) or {} }
	claim := store.claim_goal_task_for_session(goal.id, 'prepare', session.id) or { panic(err) }
	store.db.exec_param_many("INSERT INTO goal_task_attempt_workspaces (goal_id, task_id, attempt, repository_root, worktree_path, base_sha, status) VALUES (?, ?, 1, ?, ?, ?, 'ready')", [
		goal.id,
		'prepare',
		root,
		workspace_path,
		goal.tasks[0].base_sha,
	]) or { panic(err) }
	store.reconcile_goal_task_operation(claim.session_operation_id, .succeeded) or { panic(err) }
	store.close() or { panic(err) }

	mut recovered := open_store(path) or { panic(err) }
	defer { recovered.close() or {} }
	state := recovered.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert state.status == 'verifying'
	assert state.attempts[0].status == 'verifying'
	workspace := recovered.db.exec_param_many('SELECT status FROM goal_task_attempt_workspaces WHERE goal_id = ? AND task_id = ? AND attempt = 1', [
		goal.id,
		'prepare',
	]) or { panic(err) }
	assert workspace[0].val(0) == 'ready'
}

fn test_goal_task_without_verification_lease_and_without_successful_worker_recovers_uncertain() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-verification-no-success-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'store.sqlite3')
	goal := goal_task_verification_recovery_admission('goal-verification-no-success', root)
	mut store := open_store(path) or { panic(err) }
	_ = store.admit_goal(goal) or { panic(err) }
	session := store.create_session(SessionInput{ title: 'verification no success', directory: root }) or {
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
	store.db.exec_param_many("UPDATE session_operations SET status = 'failed', outcome = 'failed' WHERE session_id = ? AND id = ?", [
		session.id,
		claim.session_operation_id,
	]) or { panic(err) }
	store.close() or { panic(err) }

	mut recovered := open_store(path) or { panic(err) }
	defer { recovered.close() or {} }
	state := recovered.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert state.status == 'uncertain'
	assert state.attempts[0].status == 'uncertain'
}

fn test_expired_unbound_verification_lease_is_retryable_until_hard_deadline() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-verification-expired-unbound-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'store.sqlite3')
	goal := goal_task_verification_recovery_admission('goal-verification-expired-unbound', root)
	mut store := open_store(path) or { panic(err) }
	_ = store.admit_goal(goal) or { panic(err) }
	session := store.create_session(SessionInput{ title: 'verification retry', directory: root }) or {
		panic(err)
	}
	workspace_path := os.join_path(os.dir(root), 'veasel-goal-task-worktree-${rand.ulid()}')
	os.mkdir_all(workspace_path) or { panic(err) }
	defer { os.rmdir_all(workspace_path) or {} }
	claim := store.claim_goal_task_for_session(goal.id, 'prepare', session.id) or { panic(err) }
	store.db.exec_param_many("INSERT INTO goal_task_attempt_workspaces (goal_id, task_id, attempt, repository_root, worktree_path, base_sha, status) VALUES (?, ?, 1, ?, ?, ?, 'ready')", [
		goal.id,
		'prepare',
		root,
		workspace_path,
		goal.tasks[0].base_sha,
	]) or { panic(err) }
	store.reconcile_goal_task_operation(claim.session_operation_id, .succeeded) or { panic(err) }
	store.db.exec_param_many("UPDATE session_operations SET outcome = 'completed_with_denials' WHERE session_id = ? AND id = ?", [
		session.id,
		claim.session_operation_id,
	]) or { panic(err) }
	lease := store.claim_goal_task_verification_lease(goal.id, 'prepare', 1, 30) or { panic(err) }
	store.db.exec_param_many("UPDATE goal_task_verification_leases SET lease_expires_at = '2000-01-01T00:00:00Z' WHERE goal_id = ? AND task_id = ? AND attempt = 1", [
		goal.id,
		'prepare',
	]) or { panic(err) }
	store.close() or { panic(err) }

	mut recovered := open_store(path) or { panic(err) }
	defer { recovered.close() or {} }
	state := recovered.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert state.status == 'verifying'
	assert state.attempts[0].status == 'verifying'
	assert (recovered.goal_task_verification_dispatch_candidates() or { panic(err) }).len == 1
	lease_rows := recovered.db.exec_param_many('SELECT fencing_token, generation, verification_deadline, lease_expires_at FROM goal_task_verification_leases WHERE goal_id = ? AND task_id = ? AND attempt = 1', [
		goal.id,
		'prepare',
	]) or { panic(err) }
	assert lease_rows.len == 1
	assert lease_rows[0].val(0) == lease.fencing_token
	assert lease_rows[0].val(1).int() == lease.generation
	assert lease_rows[0].val(3) == '2000-01-01T00:00:00Z'
}

fn test_expired_bound_goal_reviewer_cannot_be_reclaimed_under_a_new_fence() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-verification-bound-reclaim-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'store.sqlite3')
	goal := goal_task_verification_test_admission()
	mut store := open_store(path) or { panic(err) }
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
	store.close() or { panic(err) }
	mut recovered := open_store(path) or { panic(err) }
	defer { recovered.close() or {} }
	state := recovered.goal_task_state(goal.id, 'prepare') or { panic(err) }
	assert state.status == 'uncertain'
	assert state.attempts[0].status == 'uncertain'
}

fn test_expired_lease_for_bound_queued_reviewer_is_re_fenced_after_restart() {
	parent := os.join_path(os.temp_dir(), 'veasel-goal-verification-queued-reviewer-${rand.ulid()}')
	root := os.join_path(parent, 'checkout')
	worktree := os.join_path(parent, 'candidate')
	os.mkdir_all(root) or { panic(err) }
	os.mkdir_all(worktree) or { panic(err) }
	defer { os.rmdir_all(parent) or {} }
	path := os.join_path(parent, 'store.sqlite3')
	goal := goal_task_verification_recovery_admission('goal-verification-queued-reviewer', root)
	mut store := open_store(path) or { panic(err) }
	_ = store.admit_goal(goal) or { panic(err) }
	parent_session := store.create_session(SessionInput{ title: 'worker', directory: worktree }) or {
		panic(err)
	}
	claim := store.claim_goal_task_for_session(goal.id, 'prepare', parent_session.id) or { panic(err) }
	store.db.exec_param_many("INSERT INTO goal_task_attempt_workspaces (goal_id, task_id, attempt, repository_root, worktree_path, base_sha, status) VALUES (?, 'prepare', 1, ?, ?, ?, 'ready')", [
		goal.id,
		root,
		worktree,
		goal.tasks[0].base_sha,
	]) or { panic(err) }
	store.reconcile_goal_task_operation(claim.session_operation_id, .succeeded) or { panic(err) }
	lease := store.claim_goal_task_verification_lease(goal.id, 'prepare', 1, 30) or { panic(err) }
	child_session := store.create_session(SessionInput{ title: 'queued reviewer', directory: worktree }) or {
		panic(err)
	}
	run_id := rand.ulid()
	store.db.exec_param_many("INSERT INTO subagent_runs (id, request_id, parent_session_id, parent_operation_id, child_session_id, agent_id, requested_title, requested_directory, depth, status) VALUES (?, 'goal-reviewer-test', ?, ?, ?, 'reviewer', 'queued reviewer', ?, 1, 'queued')", [
		run_id,
		parent_session.id,
		claim.session_operation_id,
		child_session.id,
		worktree,
	]) or { panic(err) }
	store.db.exec_param_many("INSERT INTO goal_task_verifier_bindings (id, goal_id, task_id, attempt, fencing_token, lease_generation, repository, repository_root, worktree_path, base_sha, candidate_sha, verifier_id, verifier_version, reviewer_run_id, status) VALUES ('queued-binding', ?, 'prepare', 1, ?, ?, 'owner/repo', ?, ?, ?, ?, 'review', 'builtin-review-v1', ?, 'bound')", [
		goal.id,
		lease.fencing_token,
		lease.generation.str(),
		root,
		worktree,
		goal.tasks[0].base_sha,
		'b'.repeat(40),
		run_id,
	]) or { panic(err) }
	store.db.exec_param_many("UPDATE goal_task_verification_leases SET lease_expires_at = '2000-01-01T00:00:00Z' WHERE goal_id = ? AND task_id = ? AND attempt = 1", [
		goal.id,
		'prepare',
	]) or { panic(err) }
	store.close() or { panic(err) }

	mut recovered := open_store(path) or { panic(err) }
	defer { recovered.close() or {} }
	assert (recovered.goal_task_state(goal.id, 'prepare') or { panic(err) }).status == 'verifying'
	assert (recovered.get_subagent_run(run_id) or { panic(err) }).status == 'queued'
	reclaimed := recovered.claim_goal_task_verification_lease(goal.id, 'prepare', 1, 30) or {
		panic(err)
	}
	assert reclaimed.fencing_token != lease.fencing_token
	binding := recovered.db.exec_param_many('SELECT fencing_token, lease_generation FROM goal_task_verifier_bindings WHERE id = ?',
		['queued-binding']) or { panic(err) }
	assert binding[0].val(0) == reclaimed.fencing_token
	assert binding[0].val(1).int() == reclaimed.generation
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

fn goal_task_verification_recovery_admission(id string, repository_root string) GoalAdmission {
	return GoalAdmission{
		schema_version:          1
		id:                      id
		title:                   'Verification recovery test'
		authorized_repositories: [GoalRepository{
			owner: 'owner'
			name:  'repo'
			path:  repository_root
		}]
		acceptance_criteria:     [GoalCriterion{
			id:           'ready-workspace'
			description:  'The worker produced the admitted candidate.'
			verification: 'Review the exact committed candidate.'
		}]
		deadline:                '2999-01-01T00:00:00Z'
		budget:                  GoalBudget{ max_attempts: 2, wall_seconds: 120, provider_turns: 4 }
		delivery_mode:           'draft'
		tasks:                   [GoalTask{
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
