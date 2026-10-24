module main

import os
import uuid
import crypto.sha256
import strings

fn test_subagent_run_is_idempotent_bounded_and_delivered_once_after_restart() {
	root := os.join_path(os.temp_dir(), 'veasel-subagent-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	workspace_root := init_subagent_test_repo(root)
	db_path := os.join_path(root, 'veasel.sqlite3')
	mut store := open_store(db_path) or { panic(err) }
	parent := store.create_session(SessionInput{ title: 'Parent', directory: workspace_root }) or { panic(err) }
	operation_id := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, operation_id) or { panic(err) }
	_ = store.create_subagent_run(parent.id, operation_id, 'untrusted-request', 'project-agent', 1,
		'Untrusted child', workspace_root) or {
		assert err.msg().contains('trusted built-in registry')
		SubagentRun{}
	}
	assert store.db.q_int('SELECT COUNT(*) FROM subagent_runs') or { panic(err) } == 0
	first := store.create_subagent_run(parent.id, operation_id, 'request-1', 'reviewer', 1,
		'Child', workspace_root) or { panic(err) }
	retry := store.create_subagent_run(parent.id, operation_id, 'request-1', 'reviewer', 1,
		'Child', workspace_root) or { panic(err) }
	assert retry.id == first.id
	assert retry.child_session_id == first.child_session_id
	assert first.status == 'queued'
	assert first.workspace_ready
	assert os.exists(subagent_preparation_lock_path(root, first.id) or { panic(err) })
	child_directory := (store.get_session(first.child_session_id) or { panic(err) }).directory
	expected_child_directory := os.join_path(root, 'subagent-worktrees', first.id)
	assert os.real_path(child_directory) == os.real_path(expected_child_directory)
	assert os.is_dir(os.join_path(root, 'subagent-worktrees', first.id))
	_ = store.create_subagent_run(parent.id, operation_id, 'request-1', 'explorer', 1,
		'Child', workspace_root) or {
		assert err.msg().contains('reused with different parameters')
		SubagentRun{}
	}
	_ = store.begin_subagent_run(first.id) or { panic(err) }
	_ = store.finish_subagent_run(first.id, 'completed', 'review complete', '') or { panic(err) }
	outcome := store.claim_subagent_outcome(first.id) or { panic(err) }
	assert outcome.result == 'review complete'
	assert outcome.outcome_claimed
	assert (store.claim_subagent_outcome(first.id) or { panic(err) }).result == 'review complete'
	delivery_events := store.db.q_int("SELECT COUNT(*) FROM events WHERE type = 'subagent.outcome_delivered' AND session_id = '${parent.id}'") or {
		panic(err)
	}
	assert delivery_events == 1
	parent_events := store.events_after(0) or { panic(err) }
	mut delivery_event_found := false
	for event in parent_events {
		if event.type == 'subagent.outcome_delivered' && event.data.subagent_run_id == first.id {
			assert event.data.operation_id == operation_id
			assert event.data.subagent_status == 'completed'
			assert event.data.subagent_untrusted
			delivery_event_found = true
		}
	}
	assert delivery_event_found
	queued := store.create_subagent_run(parent.id, operation_id, 'request-2', 'reviewer', 1,
		'Queued child', workspace_root) or { panic(err) }
	ready_cancelled := store.create_subagent_run(parent.id, operation_id, 'request-ready-cancelled',
		'reviewer', 1, 'Ready then cancelled', workspace_root) or { panic(err) }
	_ = store.db.exec_param_many('UPDATE subagent_runs SET workspace_ready = 0 WHERE id = ?', [queued.id]) or {
		panic(err)
	}
	_ = store.begin_subagent_run(queued.id) or {
		assert err.msg().contains('not queued')
		SubagentRun{}
	}
	running := store.create_subagent_run(parent.id, operation_id, 'request-3', 'reviewer', 1,
		'Running child', workspace_root) or { panic(err) }
	_ = store.begin_subagent_run(running.id) or { panic(err) }
	assert !(store.subagent_cancellation_requested(running.id) or { panic(err) })
	unclaimed := store.create_subagent_run(parent.id, operation_id, 'request-4', 'reviewer', 1,
		'Unclaimed child', workspace_root) or { panic(err) }
	_ = store.begin_subagent_run(unclaimed.id) or { panic(err) }
	_ = store.finish_subagent_run(unclaimed.id, 'completed', 'recovered review', '') or { panic(err) }
	_ = store.append_exchange(parent.id, operation_id, 'parent task', 'done', '', '', '', ProviderUsage{}) or { panic(err) }
	recovery_operation_id := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, recovery_operation_id) or { panic(err) }
	uncertain := store.create_subagent_run(parent.id, recovery_operation_id, 'request-5',
		'reviewer', 1, 'Interrupted child', workspace_root) or { panic(err) }
	_ = store.begin_subagent_run(uncertain.id) or { panic(err) }
	assert (store.get_subagent_run_unlocked(queued.id) or { panic(err) }).status == 'cancelled'
	assert !(store.get_subagent_run_unlocked(queued.id) or { panic(err) }).workspace_started
	assert (store.get_subagent_run_unlocked(ready_cancelled.id) or { panic(err) }).status == 'cancelled'
	assert !(store.get_subagent_run_unlocked(ready_cancelled.id) or { panic(err) }).workspace_started
	store.cleanup_unstarted_subagent_workspaces()
	assert !os.exists(os.join_path(root, 'subagent-worktrees', queued.id))
	assert !os.exists(os.join_path(root, 'subagent-worktrees', ready_cancelled.id))
	requested_cancel := store.get_subagent_run_unlocked(running.id) or { panic(err) }
	assert requested_cancel.status == 'running'
	assert requested_cancel.cancel_requested
	assert store.subagent_cancellation_requested(running.id) or { panic(err) }
	late_finish := store.finish_subagent_run(running.id, 'completed', 'late child result', '') or {
		panic(err)
	}
	assert late_finish.status == 'cancelled'
	assert late_finish.result == ''
	assert late_finish.error == 'Parent operation completed before this child run finished.'
	store.close() or { panic(err) }

	mut recovered := open_store(db_path) or { panic(err) }
	restored := recovered.get_subagent_run_unlocked(first.id) or { panic(err) }
	assert restored.status == 'completed'
	assert restored.outcome_claimed
	assert (recovered.claim_subagent_outcome(first.id) or { panic(err) }).result == 'review complete'
	recovered_unclaimed := recovered.get_subagent_run_unlocked(unclaimed.id) or { panic(err) }
	assert recovered_unclaimed.status == 'completed'
	assert recovered_unclaimed.outcome_claimed
	assert (recovered.claim_subagent_outcome(unclaimed.id) or { panic(err) }).result == 'recovered review'
	recovered_events := recovered.events_after(0) or { panic(err) }
	mut recovered_delivery_count := 0
	for event in recovered_events {
		if event.type == 'subagent.outcome_delivered' && event.data.subagent_run_id == unclaimed.id {
			assert event.session_id == parent.id
			assert event.data.operation_id == operation_id
			assert event.data.subagent_status == 'completed'
			assert event.data.subagent_untrusted
			recovered_delivery_count++
		}
	}
	assert recovered_delivery_count == 1
	recovered_uncertain := recovered.get_subagent_run_unlocked(uncertain.id) or { panic(err) }
	assert recovered_uncertain.status == 'uncertain'
	assert recovered_uncertain.outcome_claimed
	mut recovered_uncertain_delivery_count := 0
	for event in recovered_events {
		if event.type == 'subagent.outcome_delivered' && event.data.subagent_run_id == uncertain.id {
			assert event.session_id == parent.id
			assert event.data.operation_id == recovery_operation_id
			assert event.data.subagent_status == 'uncertain'
			assert event.data.subagent_untrusted
			recovered_uncertain_delivery_count++
		}
	}
	assert recovered_uncertain_delivery_count == 1
	recovered_running := recovered.get_subagent_run_unlocked(running.id) or { panic(err) }
	assert recovered_running.status == 'cancelled'
	assert recovered_running.cancel_requested
	recovered.close() or { panic(err) }

	mut restarted := open_store(db_path) or { panic(err) }
	defer { restarted.close() or {} }
	restarted_events := restarted.events_after(0) or { panic(err) }
	mut restarted_delivery_count := 0
	for event in restarted_events {
		if event.type == 'subagent.outcome_delivered' && event.data.subagent_run_id == unclaimed.id {
			restarted_delivery_count++
		}
	}
	assert restarted_delivery_count == 1
	mut restarted_uncertain_delivery_count := 0
	for event in restarted_events {
		if event.type == 'subagent.outcome_delivered' && event.data.subagent_run_id == uncertain.id {
			restarted_uncertain_delivery_count++
		}
	}
	assert restarted_uncertain_delivery_count == 1
}

fn test_builtin_subagent_profiles_grant_only_readonly_tools() {
	reviewer := builtin_subagent_profile('reviewer') or { panic(err) }
	explorer := builtin_subagent_profile('explorer') or { panic(err) }
	assert reviewer.tool_policy().allows('workspace_read_file')
	assert reviewer.tool_policy().allows('workspace_search')
	assert !reviewer.tool_policy().allows('workspace_propose_file_edit')
	assert !reviewer.tool_policy().allows('workspace_propose_shell_command')
	assert !reviewer.tool_policy().allows('subagent_run')
	assert execution_tool_class('subagent_run') == 'read'
	assert explorer.tool_policy().allowed_tools == reviewer.tool_policy().allowed_tools
	for name in reviewer.allowed_tools {
		assert workspace_agent_tools().any(it.name == name)
	}
	assert workspace_agent_tools().any(it.name == 'subagent_run')
	_ = builtin_subagent_profile('project-agent') or {
		assert err.msg().contains('trusted built-in registry')
		SubagentProfile{}
	}
}

fn test_subagent_workspace_captures_parent_changes_without_modifying_checkout() {
	git := os.find_abs_path_of_executable('git') or { return }
	_ = git
	repo := os.join_path(os.temp_dir(), 'veasel-subagent-worktree-repo-${uuid.new_v4().str()}')
	data := os.join_path(os.temp_dir(), 'veasel-subagent-worktree-data-${uuid.new_v4().str()}')
	run_id := uuid.new_v4().str()
	os.mkdir_all(repo) or { panic(err) }
	os.mkdir_all(data) or { panic(err) }
	mut workspace := SubagentWorkspace{}
	defer {
		if workspace.run_id.len > 0 {
			remove_subagent_workspace(repo, data, run_id, true) or {}
		}
		os.rmdir_all(repo) or {}
		os.rmdir_all(data) or {}
	}
	_ := run_workspace_git_command(repo, ['init', '-b', 'main']) or { panic(err) }
	_ := run_workspace_git_command(repo, ['config', 'user.email', 'veasel@example.com']) or {
		panic(err)
	}
	_ := run_workspace_git_command(repo, ['config', 'user.name', 'Veasel']) or { panic(err) }
	os.write_file(os.join_path(repo, '.gitignore'), '.env\n') or { panic(err) }
	os.write_file(os.join_path(repo, 'README.md'), 'base\n') or { panic(err) }
	_ := run_workspace_git_command(repo, ['add', '.gitignore', 'README.md']) or { panic(err) }
	_ := run_workspace_git_command(repo, ['commit', '-m', 'base']) or { panic(err) }
	os.write_file(os.join_path(repo, 'README.md'), 'staged\n') or { panic(err) }
	_ := run_workspace_git_command(repo, ['add', 'README.md']) or { panic(err) }
	os.write_file(os.join_path(repo, 'README.md'), 'staged and unstaged\n') or { panic(err) }
	os.mkdir_all(os.join_path(repo, 'scratch')) or { panic(err) }
	os.write_file(os.join_path(repo, 'scratch', 'notes.v'), 'untracked work\n') or { panic(err) }
	os.write_file(os.join_path(repo, '.env'), 'ignored secret\n') or { panic(err) }
	status_before := run_workspace_git_command(repo, ['status', '--porcelain=v1',
		'--untracked-files=all']) or {
		panic(err)
	}
	workspace = create_subagent_workspace(repo, data, run_id) or { panic(err) }
	assert workspace.path != os.real_path(repo)
	assert workspace.branch == 'veasel/subagents/${run_id}'
	readme := os.read_file(os.join_path(workspace.path, 'README.md')) or { panic(err) }
	assert readme.replace('\r\n', '\n') == 'staged and unstaged\n'
	assert os.read_file(os.join_path(workspace.path, 'scratch', 'notes.v')) or { panic(err) } == 'untracked work\n'
	assert !os.exists(os.join_path(workspace.path, '.env'))
	status_after := run_workspace_git_command(repo, ['status', '--porcelain=v1', '--untracked-files=all']) or {
		panic(err)
	}
	assert status_after == status_before
	remove_subagent_workspace(repo, data, run_id, true) or { panic(err) }
	workspace = SubagentWorkspace{}
	assert !os.exists(os.join_path(data, 'subagent-worktrees', run_id))
}

fn test_subagent_file_digest_enforces_snapshot_size_limit() {
	root := os.join_path(os.temp_dir(), 'veasel-subagent-file-digest-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'untracked.txt')
	data := strings.repeat(`x`, 64 * 1024 + 37)
	os.write_file(path, data) or { panic(err) }
	too_large := subagent_file_digest(path, data.len - 1) or {
		assert err.msg().contains('snapshot limit')
		SubagentFileDigest{}
	}
	assert too_large.byte_count == 0
	valid := subagent_file_digest(path, data.len) or { panic(err) }
	assert valid.byte_count == data.len
	assert valid.sha256 == sha256.sum(data.bytes()).hex()
}

fn test_subagent_schema_migrates_existing_v17_database() {
	root := os.join_path(os.temp_dir(), 'veasel-subagent-migration-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	db_path := os.join_path(root, 'veasel.sqlite3')
	mut store := open_store(db_path) or { panic(err) }
	initial_version := store.db.q_int('SELECT MAX(version) FROM schema_migrations') or { panic(err) }
	assert initial_version == 22
	_ = store.db.exec('DROP TABLE subagent_runs') or { panic(err) }
	_ = store.db.exec('DELETE FROM schema_migrations WHERE version = 19') or { panic(err) }
	_ = store.db.exec('DELETE FROM schema_migrations WHERE version = 20') or { panic(err) }
	_ = store.db.exec('DELETE FROM schema_migrations WHERE version = 21') or { panic(err) }
	_ = store.db.exec('DELETE FROM schema_migrations WHERE version = 22') or { panic(err) }
	_ = store.db.exec('DELETE FROM schema_migrations WHERE version = 18') or { panic(err) }
	store.close() or { panic(err) }
	mut migrated := open_store(db_path) or { panic(err) }
	defer { migrated.close() or {} }
	assert migrated.db.q_int("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'subagent_runs'") or {
		panic(err)
	} == 1
	migrated_version := migrated.db.q_int('SELECT MAX(version) FROM schema_migrations') or { panic(err) }
	assert migrated_version == 22
	assert migrated.db.q_int("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'subagent_runs_unclaimed_outcome'") or {
		panic(err)
	} == 1
	parent := migrated.create_session(SessionInput{
		title:     'Indexed outcome parent'
		directory: root
	}) or { panic(err) }
	migrated.db.begin() or { panic(err) }
	for i in 0 .. 512 {
		child_session_id := uuid.new_v4().str()
		_ = migrated.db.exec_param_many('INSERT INTO sessions (id, title, directory) VALUES (?, ?, ?)',
			[child_session_id, 'Indexed outcome child', root]) or { panic(err) }
		_ = migrated.db.exec_param_many("INSERT INTO subagent_runs (id, request_id, parent_session_id, parent_operation_id, child_session_id, agent_id, requested_title, requested_directory, depth, status, outcome_claimed) VALUES (?, ?, ?, ?, ?, 'reviewer', 'Indexed outcome child', ?, 1, 'completed', ?)",
			[uuid.new_v4().str(), i.str(), parent.id, 'indexed-outcome-test', child_session_id,
				root, if i == 511 { '0' } else { '1' }]) or { panic(err) }
	}
	migrated.db.commit() or { panic(err) }
	_ = migrated.db.exec('ANALYZE subagent_runs') or { panic(err) }
	// Force this access path so planner versions cannot prefer a table scan for
	// one unclaimed row. Check the indexed columns separately: EXPLAIN's
	// "covering index" wording differs across bundled/system SQLite versions.
	index_columns := migrated.db.exec("PRAGMA index_info('subagent_runs_unclaimed_outcome')") or {
		panic(err)
	}.map(it.val(2))
	assert index_columns == ['id', 'parent_session_id', 'parent_operation_id', 'status']
	query_plan := migrated.db.exec("EXPLAIN QUERY PLAN SELECT id, parent_session_id, parent_operation_id, status FROM subagent_runs INDEXED BY subagent_runs_unclaimed_outcome WHERE outcome_claimed = 0 AND status IN ('completed', 'failed', 'cancelled', 'uncertain')") or {
		panic(err)
	}
	assert query_plan.any(it.val(3).contains('subagent_runs_unclaimed_outcome'))
}

fn test_subagent_run_enforces_concurrency_and_marks_running_as_uncertain() {
	root := os.join_path(os.temp_dir(), 'veasel-subagent-recovery-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	workspace_root := init_subagent_test_repo(root)
	db_path := os.join_path(root, 'veasel.sqlite3')
	mut store := open_store(db_path) or { panic(err) }
	parent := store.create_session(SessionInput{ title: 'Parent', directory: workspace_root }) or { panic(err) }
	operation_id := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, operation_id) or { panic(err) }
	mut running_ids := []string{cap: max_active_subagent_runs_per_parent}
	for i in 0 .. max_active_subagent_runs_per_parent {
		run := store.create_subagent_run(parent.id, operation_id, 'request-${i}', 'explorer', 1,
			'Child ${i}', workspace_root) or { panic(err) }
		_ = store.begin_subagent_run(run.id) or { panic(err) }
		running_ids << run.id
	}
	over_limit := store.create_subagent_run(parent.id, operation_id, 'request-over-limit', 'explorer', 1,
		'Overflow', workspace_root) or {
		assert err.msg().contains('concurrency limit')
		SubagentRun{}
	}
	assert over_limit.id == ''
	_ = store.finish_subagent_run(running_ids[0], 'failed', '', 'finished before restart') or {
		panic(err)
	}
	queued := store.create_subagent_run(parent.id, operation_id, 'request-after-slot-release',
		'explorer', 1, 'Queued at restart', workspace_root) or { panic(err) }
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

fn test_unstarted_workspace_cleanup_skips_live_preparation() {
	root := os.join_path(os.temp_dir(), 'veasel-subagent-live-preparation-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	workspace_root := init_subagent_test_repo(root)
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	parent := store.create_session(SessionInput{ title: 'Parent', directory: workspace_root }) or {
		panic(err)
	}
	operation_id := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, operation_id) or { panic(err) }
	run := store.create_subagent_run(parent.id, operation_id, 'request', 'reviewer', 1, 'Child',
		workspace_root) or { panic(err) }
	_ = store.append_exchange(parent.id, operation_id, 'parent task', 'done', '', '', '', ProviderUsage{}) or {
		panic(err)
	}
	child := store.get_session(run.child_session_id) or { panic(err) }
	expected_child_directory := os.join_path(root, 'subagent-worktrees', run.id)
	assert os.real_path(child.directory) == os.real_path(expected_child_directory)
	store.active_subagent_preparations[run.id] = true
	store.cleanup_unstarted_subagent_workspaces()
	path := os.join_path(root, 'subagent-worktrees', run.id)
	assert os.is_dir(path)
	store.active_subagent_preparations.delete(run.id)
	store.cleanup_unstarted_subagent_workspaces()
	assert !os.exists(path)
	cleaned_child := store.get_session(run.child_session_id) or { panic(err) }
	assert cleaned_child.directory == workspace_root
}

fn test_subagent_preparation_lock_keeps_one_inode_and_excludes_same_process_stores() {
	root := os.join_path(os.temp_dir(), 'veasel-subagent-lock-inode-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	lock_path := os.join_path(root, 'preparation.lock')
	mut first := new_subagent_preparation_lock(lock_path) or { panic(err) }
	mut second := new_subagent_preparation_lock(lock_path) or { panic(err) }
	first.acquire() or { panic(err) }
	assert !second.try_acquire()
	assert first.release()
	assert os.exists(lock_path)
	assert second.try_acquire()
	assert second.release()
	assert os.exists(lock_path)
}

fn init_subagent_test_repo(root string) string {
	repo := os.join_path(root, 'workspace')
	os.mkdir_all(repo) or { panic(err) }
	_ := run_workspace_git_command(repo, ['init', '-b', 'main']) or { panic(err) }
	_ := run_workspace_git_command(repo, ['config', 'user.email', 'veasel@example.com']) or {
		panic(err)
	}
	_ := run_workspace_git_command(repo, ['config', 'user.name', 'Veasel']) or { panic(err) }
	os.write_file(os.join_path(repo, 'README.md'), 'base\n') or { panic(err) }
	_ := run_workspace_git_command(repo, ['add', 'README.md']) or { panic(err) }
	_ := run_workspace_git_command(repo, ['commit', '-m', 'base']) or { panic(err) }
	return repo
}
