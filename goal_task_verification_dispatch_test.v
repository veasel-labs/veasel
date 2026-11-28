module main

import os
import rand

struct GoalVerificationDispatchRepoFixture {
	root          string
	worktree      string
	base_sha      string
	candidate_sha string
}

fn test_goal_task_verification_dispatch_candidates_are_current_and_receipt_free() {
	fixture := new_goal_verification_dispatch_repo_fixture() or { panic(err) }
	defer { os.rmdir_all(os.dir(fixture.root)) or {} }
	root := os.join_path(os.dir(fixture.root), 'veasel-data-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	store_path := os.join_path(root, 'store.sqlite3')
	goal := GoalAdmission{
		schema_version:          1
		id:                      'goal-verifier-dispatch'
		title:                   'Dispatch a verified worker result'
		authorized_repositories: [GoalRepository{
			owner: 'owner'
			name:  'repo'
			path:  fixture.root
		}]
		acceptance_criteria:     [GoalCriterion{
			id:           'scoped-change'
			description:  'The change stays within docs.'
			verification: 'Review the committed candidate.'
		}]
		deadline:                '2999-01-01T00:00:00Z'
		budget:                  GoalBudget{ max_attempts: 2, wall_seconds: 120, provider_turns: 4 }
		delivery_mode:           'draft'
		tasks:                   [GoalTask{
			id:                'review-docs'
			title:             'Review documentation change'
			repository:        'owner/repo'
			base_sha:          fixture.base_sha
			paths:             ['docs']
			recipe:            'feature'
			runner:            'local-v'
			verifier:          'review'
			verifier_provider: 'openai'
			verifier_model:    'review-model'
		}]
	}
	mut store := open_store(store_path) or { panic(err) }
	defer { store.close() or {} }
	_ = store.admit_goal(goal) or { panic(err) }
	session := store.create_session(SessionInput{ title: 'Worker', directory: fixture.worktree }) or {
		panic(err)
	}
	claim := store.claim_goal_task_for_session(goal.id, 'review-docs', session.id) or { panic(err) }
	store.db.exec_param_many("INSERT INTO goal_task_attempt_workspaces (goal_id, task_id, attempt, repository_root, worktree_path, base_sha, status) VALUES (?, ?, 1, ?, ?, ?, 'ready')", [
		goal.id,
		'review-docs',
		fixture.root,
		fixture.worktree,
		fixture.base_sha,
	]) or { panic(err) }
	store.reconcile_goal_task_operation(claim.session_operation_id, .succeeded) or { panic(err) }

	candidates := store.goal_task_verification_dispatch_candidates() or { panic(err) }
	assert candidates.len == 1
	assert candidates[0].goal_id == goal.id
	assert candidates[0].task_id == 'review-docs'
	assert candidates[0].attempt == 1
	assert candidates[0].parent_session_id == session.id
	assert candidates[0].parent_operation_id == claim.session_operation_id
	assert candidates[0].goal.id == goal.id
	assert candidates[0].task.base_sha == fixture.base_sha
	assert candidates[0].task.verifier_provider == 'openai'
	store.close() or { panic(err) }
	store = open_store(store_path) or { panic(err) }
	assert (store.goal_task_verification_dispatch_candidates() or { panic(err) }).len == 1
	lease := store.claim_goal_task_verification_lease(goal.id, 'review-docs', 1, 60) or {
		panic(err)
	}
	store.db.exec_param_many("UPDATE goal_task_verification_leases SET lease_expires_at = '2000-01-01T00:00:00Z' WHERE goal_id = ? AND task_id = ? AND attempt = 1", [
		goal.id,
		'review-docs',
	]) or { panic(err) }
	store.close() or { panic(err) }
	store = open_store(store_path) or { panic(err) }
	assert (store.goal_task_state(goal.id, 'review-docs') or { panic(err) }).status == 'verifying'
	assert (store.goal_task_verification_dispatch_candidates() or { panic(err) }).len == 1
	assert lease.generation == 1
	store.db.exec_param_many("INSERT INTO goal_task_verifier_bindings (id, goal_id, task_id, attempt, fencing_token, lease_generation, repository, repository_root, worktree_path, base_sha, candidate_sha, verifier_id, verifier_version, status) VALUES ('reserved-dispatch-test', ?, ?, 1, ?, ?, 'owner/repo', ?, ?, ?, ?, 'review', 'builtin-review-v1', 'reserved')", [
		goal.id,
		'review-docs',
		lease.fencing_token,
		lease.generation.str(),
		fixture.root,
		fixture.worktree,
		fixture.base_sha,
		fixture.candidate_sha,
	]) or { panic(err) }
	store.close() or { panic(err) }
	store = open_store(store_path) or { panic(err) }
	assert (store.goal_task_state(goal.id, 'review-docs') or { panic(err) }).status == 'verifying'
	assert (store.goal_task_verification_dispatch_candidates() or { panic(err) }).len == 1

	store.db.exec_param_many('UPDATE goal_task_attempt_workspaces SET repository_root = ? WHERE goal_id = ? AND task_id = ? AND attempt = 1', [
		fixture.worktree,
		goal.id,
		'review-docs',
	]) or { panic(err) }
	assert (store.goal_task_verification_dispatch_candidates() or { panic(err) }).len == 0
	store.db.exec_param_many('UPDATE goal_task_attempt_workspaces SET repository_root = ? WHERE goal_id = ? AND task_id = ? AND attempt = 1', [
		fixture.root,
		goal.id,
		'review-docs',
	]) or { panic(err) }

	store.db.exec_param_many("UPDATE goal_task_verifier_bindings SET id = 'binding-dispatch-test' WHERE goal_id = ? AND task_id = ? AND attempt = 1", [
		goal.id,
		'review-docs',
	]) or { panic(err) }
	store.db.exec_param_many("INSERT INTO goal_task_verification_receipts (goal_id, task_id, attempt, binding_id, repository, repository_root, worktree_path, base_sha, candidate_sha, verifier_id, verifier_version, reviewer_provider, reviewer_model, reviewer_run_id, lease_generation, verdict, evidence, changed_paths_json) VALUES (?, ?, 1, 'binding-dispatch-test', 'owner/repo', ?, ?, ?, ?, 'review', 'builtin-review-v1', 'openai', 'review-model', 'run-dispatch-test', 1, 'pass', 'Reviewed candidate.', '[]')", [
		goal.id,
		'review-docs',
		fixture.root,
		fixture.worktree,
		fixture.base_sha,
		fixture.candidate_sha,
	]) or { panic(err) }
	assert (store.goal_task_verification_dispatch_candidates() or { panic(err) }).len == 0
}

fn test_list_bound_goal_task_verifiers_and_concurrent_reconcile_serialize_store_access() {
	fixture := new_goal_verification_dispatch_repo_fixture() or { panic(err) }
	defer { os.rmdir_all(os.dir(fixture.root)) or {} }
	root := os.join_path(os.dir(fixture.root), 'veasel-data-concurrent-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	goal := GoalAdmission{
		schema_version:          1
		id:                      'goal-verifier-concurrent'
		title:                   'Serialize verifier binding lookups under store.mu'
		authorized_repositories: [GoalRepository{
			owner: 'owner'
			name:  'repo'
			path:  fixture.root
		}]
		acceptance_criteria:     [GoalCriterion{
			id:           'scoped-change'
			description:  'The change stays within docs.'
			verification: 'Review the committed candidate.'
		}]
		deadline:                '2999-01-01T00:00:00Z'
		budget:                  GoalBudget{ max_attempts: 2, wall_seconds: 120, provider_turns: 4 }
		delivery_mode:           'draft'
		tasks:                   [GoalTask{
			id:                'review-docs'
			title:             'Review documentation change'
			repository:        'owner/repo'
			base_sha:          fixture.base_sha
			paths:             ['docs']
			recipe:            'feature'
			runner:            'local-v'
			verifier:          'review'
			verifier_provider: 'openai'
			verifier_model:    'review-model'
		}]
	}
	mut store := open_store(os.join_path(root, 'store.sqlite3')) or { panic(err) }
	mut app := new_app(store, os.join_path(root, 'plugins'))
	defer { app.close() }
	_ = store.admit_goal(goal) or { panic(err) }
	session := store.create_session(SessionInput{ title: 'Worker', directory: fixture.worktree }) or {
		panic(err)
	}
	claim := store.claim_goal_task_for_session(goal.id, 'review-docs', session.id) or { panic(err) }
	store.db.exec_param_many("INSERT INTO goal_task_attempt_workspaces (goal_id, task_id, attempt, repository_root, worktree_path, base_sha, status) VALUES (?, ?, 1, ?, ?, ?, 'ready')", [
		goal.id,
		'review-docs',
		fixture.root,
		fixture.worktree,
		fixture.base_sha,
	]) or { panic(err) }
	store.reconcile_goal_task_operation(claim.session_operation_id, .succeeded) or { panic(err) }
	lease := store.claim_goal_task_verification_lease(goal.id, 'review-docs', 1, 60) or {
		panic(err)
	}
	store.db.exec_param_many("INSERT INTO goal_task_verifier_bindings (id, goal_id, task_id, attempt, fencing_token, lease_generation, repository, repository_root, worktree_path, base_sha, candidate_sha, verifier_id, verifier_version, reviewer_run_id, status) VALUES ('bound-run-1', ?, 'review-docs', 1, ?, ?, 'owner/repo', ?, ?, ?, ?, 'review', 'builtin-review-v1', 'reviewer-run-bound', 'bound')", [
		goal.id,
		lease.fencing_token,
		lease.generation.str(),
		fixture.root,
		fixture.worktree,
		fixture.base_sha,
		fixture.candidate_sha,
	]) or { panic(err) }
	bound := store.list_bound_goal_task_verifiers('reviewer-run-bound') or { panic(err) }
	assert bound == [
		BoundGoalTaskVerifier{
			id:      'bound-run-1'
			goal_id: goal.id
			task_id: 'review-docs'
			attempt: 1
		},
	]
	assert (store.list_bound_goal_task_verifiers('other-run') or { panic(err) }).len == 0

	mut workers := []thread{}
	for worker_idx in 0 .. 4 {
		workers << spawn fn (app &App, mut store Store, worker_idx int) {
			for iter in 0 .. 25 {
				app.reconcile_goal_task_verifier_run('nonexistent-run-${worker_idx}-${iter}')
				assert (store.list_bound_goal_task_verifiers('reviewer-run-bound') or { panic(err) }).len == 1
			}
		}(app, mut store, worker_idx)
	}
	for worker in workers {
		worker.wait()
	}
}

fn test_no_value_copied_store_mutex_in_backend_sources() {
	root := os.dir(@FILE)
	entries := os.ls(root) or { panic(err) }
	for entry in entries {
		if !entry.ends_with('.v') {
			continue
		}
		content := os.read_file(os.join_path(root, entry)) or { panic(err) }
		for idx, line in content.split_into_lines() {
			trimmed := line.trim_space()
			if trimmed.starts_with('//') {
				continue
			}
			if trimmed.contains(':=') && !trimmed.contains('.mutex')
				&& (trimmed.ends_with('.mu') || trimmed.contains('.mu ')
					|| trimmed.contains('.mu\t')) {
				assert false, '${entry}:${idx + 1} copies a value-type .mu mutex: ${trimmed}'
			}
		}
	}
}

fn new_goal_verification_dispatch_repo_fixture() !GoalVerificationDispatchRepoFixture {
	parent := os.join_path(os.temp_dir(), 'veasel-goal-dispatch-repo-${rand.ulid()}')
	root := os.join_path(parent, 'checkout')
	worktree := os.join_path(parent, 'goal-candidate')
	hooks := os.join_path(parent, 'empty-hooks')
	os.mkdir_all(os.join_path(root, 'docs'))!
	os.mkdir_all(hooks)!
	os.write_file(os.join_path(root, 'docs/README.md'), 'base')!
	_ = run_workspace_git_command_output(root, ['init', '--quiet', '-b', 'main'], 1024)!
	_ = run_workspace_git_command_output(root, ['config', 'user.name', 'Veasel Fixture'], 1024)!
	_ = run_workspace_git_command_output(root, ['config', 'user.email', 'fixture@example.invalid'], 1024)!
	_ = run_workspace_git_command_output(root, ['config', 'core.hooksPath', hooks], 1024)!
	_ = run_workspace_git_command_output(root, ['remote', 'add', 'origin',
		'https://github.com/owner/repo.git'], 1024)!
	_ = run_workspace_git_command_output(root, ['add', '--', 'docs/README.md'], 1024)!
	_ = run_workspace_git_command_output(root,
		['-c', 'commit.gpgsign=false', 'commit', '--no-gpg-sign', '-m', 'base'], 1024)!
	base_sha := run_workspace_git_command_output(root, ['rev-parse', '--verify', 'HEAD'], 1024)!.trim_space()
	_ = run_workspace_git_command_output(root,
		['worktree', 'add', '--detach', worktree, base_sha], 4096)!
	os.write_file(os.join_path(worktree, 'docs/README.md'), 'candidate')!
	_ = run_workspace_git_command_output(worktree, ['add', '--', 'docs/README.md'], 1024)!
	_ = run_workspace_git_command_output(worktree,
		['-c', 'commit.gpgsign=false', 'commit', '--no-gpg-sign', '-m', 'candidate'], 1024)!
	candidate_sha := run_workspace_git_command_output(worktree, ['rev-parse', '--verify', 'HEAD'], 1024)!.trim_space()
	return GoalVerificationDispatchRepoFixture{
		root:          os.real_path(root)
		worktree:      os.real_path(worktree)
		base_sha:      base_sha
		candidate_sha: candidate_sha
	}
}
