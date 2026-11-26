module main

import os
import rand
import time

struct GoalTaskWorktreeFixture {
	root   string
	commit string
}

fn test_goal_task_attempt_worktree_isolated_exact_base_and_persists_identity() {
	fixture := new_goal_task_worktree_fixture('https://github.com/owner/repo.git') or {
		panic(err)
	}
	defer {
		_ = run_workspace_git_command(fixture.root, ['worktree', 'remove', '--force', os.join_path(os.dir(fixture.root), 'veasel-data', goal_task_worktree_root_name,
			'goal-worktree-test', 'prepare', '1')]) or { '' }
		os.rmdir_all(os.dir(fixture.root)) or {}
	}
	os.write_file(os.join_path(fixture.root, 'parent-only.txt'), 'uncommitted parent data') or {
		panic(err)
	}
	data_dir := os.join_path(os.dir(fixture.root), 'veasel-data')
	os.mkdir_all(data_dir) or { panic(err) }
	mut store := open_store(os.join_path(data_dir, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	goal := goal_task_worktree_test_admission(fixture)
	_ = store.admit_goal(goal) or { panic(err) }
	session := store.create_session(SessionInput{ title: 'goal worktree test', directory: fixture.root }) or {
		panic(err)
	}
	claim := store.claim_goal_task_for_session(goal.id, 'prepare', session.id) or { panic(err) }
	worktree := store.prepare_goal_task_attempt_worktree(goal.id, 'prepare', claim) or {
		panic(err)
	}
	assert worktree.status == 'ready'
	assert worktree.base_sha == fixture.commit
	assert worktree.repository_root == fixture.root
	assert worktree.path.starts_with(os.real_path(data_dir) + os.path_separator)
	assert !goal_task_path_is_within(fixture.root, worktree.path)
	head := run_goal_git_command_output_until(worktree.path,
		['--no-replace-objects', 'rev-parse', '--verify', '--end-of-options', 'HEAD'],
		max_goal_git_output_bytes, time.now().add(max_goal_preflight_elapsed)) or { panic(err) }
	assert head.trim_space() == fixture.commit
	status := run_goal_git_command_output_until(worktree.path,
		['--no-replace-objects', 'status', '--porcelain=v1', '--untracked-files=all'],
		max_goal_git_output_bytes, time.now().add(max_goal_preflight_elapsed)) or { panic(err) }
	assert status == ''
	parent_only := os.read_file(os.join_path(fixture.root, 'parent-only.txt')) or { panic(err) }
	assert parent_only == 'uncommitted parent data'
	assert !os.exists(os.join_path(worktree.path, 'parent-only.txt'))
	parent_status := run_goal_git_command_output_until(fixture.root,
		['--no-replace-objects', 'status', '--porcelain=v1', '--untracked-files=all'],
		max_goal_git_output_bytes, time.now().add(max_goal_preflight_elapsed)) or { panic(err) }
	assert parent_status.contains('parent-only.txt')
	rows := store.db.exec_param_many('SELECT repository_root, worktree_path, base_sha, status FROM goal_task_attempt_workspaces WHERE goal_id = ? AND task_id = ? AND attempt = ?', [
		goal.id,
		'prepare',
		'1',
	]) or { panic(err) }
	assert rows.len == 1
	assert rows[0].val(0) == fixture.root
	assert rows[0].val(1) == worktree.path
	assert rows[0].val(2) == fixture.commit
	assert rows[0].val(3) == 'ready'
	_ = store.db.exec_param_many("UPDATE goal_task_attempts SET owner_pid = 0, owner_start_id = '' WHERE goal_id = ? AND task_id = ? AND attempt = ?", [
		goal.id,
		'prepare',
		'1',
	]) or { panic(err) }
	store.close() or { panic(err) }
	store = open_store(os.join_path(data_dir, 'veasel.sqlite3')) or { panic(err) }
	recovered := store.db.exec_param_many('SELECT status FROM goal_task_attempt_workspaces WHERE goal_id = ? AND task_id = ? AND attempt = ?', [
		goal.id,
		'prepare',
		'1',
	]) or { panic(err) }
	assert recovered.len == 1
	assert recovered[0].val(0) == 'uncertain'
}

fn test_goal_task_attempt_worktree_rejects_invalid_sha_collision_and_escaping_identity() {
	fixture := new_goal_task_worktree_fixture('https://github.com/owner/repo.git') or {
		panic(err)
	}
	defer { os.rmdir_all(os.dir(fixture.root)) or {} }
	parent := os.join_path(os.dir(fixture.root), 'worktree-path-tests')
	os.mkdir_all(parent) or { panic(err) }
	path := os.join_path(parent, 'candidate')
	base := GoalTaskWorktree{
		goal_id:         'goal'
		task_id:         'task'
		attempt:         1
		repository_root: fixture.root
		path:            path
		base_sha:        fixture.commit
		status:          'preparing'
	}
	for sha in ['', 'abc', fixture.commit.to_upper()] {
		if _ := create_goal_task_worktree(fixture.root, GoalTaskWorktree{ ...base, base_sha: sha }) {
			assert false, 'accepted invalid pinned commit ${sha}'
		}
	}
	os.mkdir(path) or { panic(err) }
	if _ := create_goal_task_worktree(fixture.root, base) {
		assert false, 'accepted a colliding worktree path'
	}
	if _ := goal_task_attempt_worktree_path(os.join_path(parent, 'store.sqlite3'), fixture.root,
		'../escape', 'task', 1) {
		assert false, 'accepted a path-escaping goal id'
	}
	if _ := goal_task_attempt_worktree_path(os.join_path(parent, 'store.sqlite3'), fixture.root,
		'goal', '../escape', 1) {
		assert false, 'accepted a path-escaping task id'
	}
}

fn test_goal_task_attempt_worktree_rejects_symlinked_storage_root() {
	fixture := new_goal_task_worktree_fixture('https://github.com/owner/repo.git') or {
		panic(err)
	}
	defer { os.rmdir_all(os.dir(fixture.root)) or {} }
	parent := os.join_path(os.dir(fixture.root), 'worktree-symlink-test')
	data := os.join_path(parent, 'data')
	external := os.join_path(parent, 'external')
	os.mkdir_all(data) or { panic(err) }
	os.mkdir_all(external) or { panic(err) }
	os.symlink(external, os.join_path(data, goal_task_worktree_root_name)) or { panic(err) }
	if _ := goal_task_attempt_worktree_path(os.join_path(data, 'veasel.sqlite3'), fixture.root,
		'goal', 'task', 1) {
		assert false, 'accepted a symlinked goal worktree storage root'
	}
}

fn goal_task_worktree_test_admission(fixture GoalTaskWorktreeFixture) GoalAdmission {
	return GoalAdmission{
		schema_version:          1
		id:                      'goal-worktree-test'
		title:                   'Prepare exact-base worktree'
		authorized_repositories: [GoalRepository{
			owner: 'owner'
			name:  'repo'
			path:  fixture.root
		}]
		acceptance_criteria:     [GoalCriterion{
			id:           'clean-base'
			description:  'Prepare a clean worktree at the admitted base'
			verification: 'Check HEAD and worktree status'
		}]
		deadline:                '2027-01-01T00:00:00Z'
		budget:                  GoalBudget{ max_attempts: 1, wall_seconds: 60, provider_turns: 1 }
		delivery_mode:           'report'
		tasks:                   [GoalTask{
			id:         'prepare'
			title:      'Prepare worktree'
			repository: 'owner/repo'
			base_sha:   fixture.commit
			paths:      ['docs/README.md']
			recipe:     'research'
			runner:     'test-runner'
			verifier:   'test-verifier'
		}]
	}
}

fn new_goal_task_worktree_fixture(remote string) !GoalTaskWorktreeFixture {
	parent := os.join_path(os.temp_dir(), 'veasel-goal-worktree-fixture-${rand.ulid()}')
	root := os.join_path(parent, 'checkout')
	docs := os.join_path(root, 'docs')
	hooks := os.join_path(parent, 'empty-hooks')
	os.mkdir_all(docs)!
	os.mkdir_all(hooks)!
	os.write_file(os.join_path(docs, 'README.md'), 'fixture')!
	_ = run_workspace_git_command_output(root, ['init', '--quiet', '-b', 'main'], 1024)!
	_ = run_workspace_git_command_output(root, ['config', 'user.name', 'Veasel Fixture'], 1024)!
	_ = run_workspace_git_command_output(root, ['config', 'user.email', 'fixture@example.invalid'], 1024)!
	_ = run_workspace_git_command_output(root, ['config', 'core.hooksPath', hooks], 1024)!
	_ = run_workspace_git_command_output(root, ['remote', 'add', 'origin', remote], 1024)!
	_ = run_workspace_git_command_output(root, ['add', '--', 'docs/README.md'], 1024)!
	_ = run_workspace_git_command_output(root,
		['-c', 'commit.gpgsign=false', 'commit', '--no-gpg-sign', '-m', 'fixture'], 1024)!
	commit := run_workspace_git_command_output(root, ['rev-parse', '--verify', 'HEAD'], 1024)!
	return GoalTaskWorktreeFixture{
		root:   os.real_path(root)
		commit: commit.trim_space()
	}
}
