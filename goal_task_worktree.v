module main

import db.sqlite
import json2
import os
import time

const goal_task_worktree_root_name = 'goal-task-worktrees'

struct GoalTaskWorktree {
	goal_id         string
	task_id         string
	attempt         int
	repository_root string
	path            string
	base_sha        string
	status          string
}

fn migrate_goal_task_workspaces(mut db sqlite.DB) ! {
	db.begin()!
	defer { db.rollback() or {} }
	db.exec("CREATE TABLE IF NOT EXISTS goal_task_attempt_workspaces (
		goal_id TEXT NOT NULL,
		task_id TEXT NOT NULL,
		attempt INTEGER NOT NULL CHECK (attempt > 0),
		repository_root TEXT NOT NULL,
		worktree_path TEXT NOT NULL,
		base_sha TEXT NOT NULL,
		status TEXT NOT NULL CHECK (status IN ('preparing', 'ready', 'uncertain')),
		created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
		updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
		PRIMARY KEY (goal_id, task_id, attempt),
		UNIQUE (worktree_path),
		FOREIGN KEY (goal_id, task_id, attempt) REFERENCES goal_task_attempts(goal_id, task_id, attempt) ON DELETE CASCADE
	)")!
	db.exec('INSERT OR IGNORE INTO schema_migrations (version) VALUES (39)')!
	db.commit()!
}

// prepare_goal_task_attempt_worktree only prepares an isolated, exact-base
// checkout for an already claimed attempt. It never starts an agent or runs
// repository commands. Admission and checkout identity/scope are revalidated
// immediately before Git creates the worktree.
fn (mut store Store) prepare_goal_task_attempt_worktree(goal_id string, task_id string,
	claim GoalTaskClaim) !GoalTaskWorktree {
	if claim.fencing_token.len == 0 || claim.state.attempt_count <= 0
		|| claim.state.status != 'running' {
		return error('goal task attempt is not a valid linked running claim')
	}
	manifest := store.admitted_goal_manifest(goal_id)!
	if manifest == '' {
		return error('goal admission not found')
	}
	goal := json2.decode[GoalAdmission](manifest)!
	validate_goal_admission(goal)!
	mut selected_task := GoalTask{}
	mut found_task := false
	for task in goal.tasks {
		if task.id == task_id {
			selected_task = task
			found_task = true
			break
		}
	}
	if !found_task {
		return error('goal task not found')
	}
	checkouts := verify_goal_checkouts(goal)!
	key := selected_task.repository.to_lower()
	checkout := checkouts[key] or { return error('goal task repository was not verified') }
	worktree_path := goal_task_attempt_worktree_path(store.path, checkout.path, goal.id,
		selected_task.id, claim.state.attempt_count)!
	intent := GoalTaskWorktree{
		goal_id:         goal.id
		task_id:         selected_task.id
		attempt:         claim.state.attempt_count
		repository_root: checkout.path
		path:            worktree_path
		base_sha:        selected_task.base_sha
		status:          'preparing'
	}
	store.record_goal_task_worktree_intent(intent, claim)!
	prepared := create_goal_task_worktree(checkout.path, intent) or {
		store.classify_goal_task_worktree(intent, claim, 'uncertain') or {}
		return err
	}
	store.classify_goal_task_worktree(prepared, claim, 'ready') or {
		store.classify_goal_task_worktree(prepared, claim, 'uncertain') or {}
		return err
	}
	return GoalTaskWorktree{ ...prepared, status: 'ready' }
}

fn goal_task_attempt_worktree_path(store_path string, repository_root string, goal_id string,
	task_id string, attempt int) !string {
	if store_path == ':memory:' || attempt <= 0 || !valid_goal_id(goal_id)
		|| !valid_goal_id(task_id) {
		return error('goal task worktree identity is invalid')
	}
	if workspace_has_hidden_controls(store_path) {
		return error('goal task worktree store path is invalid')
	}
	abs_store_path := if os.is_abs_path(store_path) { store_path } else { os.abs_path(store_path) }
	store_directory := os.dir(abs_store_path)
	if !os.is_dir(store_directory) || os.is_link(store_directory) {
		return error('goal task worktree store directory must exist and must not be a symlink')
	}
	canonical_store_directory := os.real_path(store_directory)
	if canonical_store_directory != store_directory.trim_right(os.path_separator) {
		return error('goal task worktree store directory must be canonical')
	}
	root := os.join_path(canonical_store_directory, goal_task_worktree_root_name)
	if os.is_link(root) {
		return error('goal task worktree root must not be a symlink')
	}
	if !os.exists(root) {
		os.mkdir(root) or {
			if !os.is_dir(root) || os.is_link(root) {
				return error('goal task worktree root cannot be created safely')
			}
		}
	}
	if !os.is_dir(root) || os.is_link(root) {
		return error('goal task worktree root must be a directory')
	}
	mut parent := root
	for component in [goal_id, task_id] {
		parent = os.join_path(parent, component)
		if os.is_link(parent) {
			return error('goal task worktree path crosses a symlink')
		}
		if !os.exists(parent) {
			os.mkdir(parent) or {
				if !os.is_dir(parent) || os.is_link(parent) {
					return error('goal task worktree path cannot be created safely')
				}
			}
		}
		if !os.is_dir(parent) || os.is_link(parent) {
			return error('goal task worktree path crosses a non-directory')
		}
	}
	path := os.join_path(parent, '${attempt}')
	canonical_parent := os.real_path(parent)
	if canonical_parent != parent.trim_right(os.path_separator) || os.exists(path)
		|| os.is_link(path) || path.len > max_workspace_git_worktree_path_len {
		return error('goal task worktree path collides or is not canonical')
	}
	if goal_task_path_is_within(repository_root, path) {
		return error('goal task worktree must be outside the source checkout')
	}
	return path
}

fn goal_task_path_is_within(parent string, child string) bool {
	mut canonical_parent := parent.replace('\\', '/').trim_right('/')
	mut candidate := child.replace('\\', '/').trim_right('/')
	$if windows {
		canonical_parent = canonical_parent.to_lower()
		candidate = candidate.to_lower()
	}
	return candidate == canonical_parent || candidate.starts_with(canonical_parent + '/')
}

fn create_goal_task_worktree(repository_root string, intent GoalTaskWorktree) !GoalTaskWorktree {
	if !valid_goal_sha(intent.base_sha) || intent.status != 'preparing'
		|| goal_task_path_is_within(repository_root, intent.path) {
		return error('goal task worktree request is invalid')
	}
	if os.exists(intent.path) || os.is_link(intent.path) {
		return error('goal task worktree path collides')
	}
	goal_task_worktree_refuse_command_config(repository_root)!
	stdout, truncated := run_untrusted_git(repository_root,
		['--no-replace-objects', 'worktree', 'add', '--detach', intent.path, intent.base_sha],
		max_goal_git_output_bytes)!
	if truncated || stdout.len > max_goal_git_output_bytes {
		return error('goal task worktree Git output exceeds its size limit')
	}
	canonical_path := os.real_path(intent.path)
	if canonical_path != intent.path || goal_task_path_is_within(repository_root, canonical_path) {
		return error('created goal task worktree path is not canonical or isolated')
	}
	head := run_goal_git_command_output_until(canonical_path,
		['--no-replace-objects', 'rev-parse', '--verify', '--end-of-options', 'HEAD'],
		max_goal_git_output_bytes, time.now().add(max_goal_preflight_elapsed))!
	if head.trim_space() != intent.base_sha {
		return error('created goal task worktree does not match the exact admitted base SHA')
	}
	status := run_goal_git_command_output_until(canonical_path,
		['--no-replace-objects', 'status', '--porcelain=v1', '--untracked-files=all'],
		max_goal_git_output_bytes, time.now().add(max_goal_preflight_elapsed))!
	if status.len != 0 {
		return error('created goal task worktree is not clean')
	}
	return GoalTaskWorktree{ ...intent, path: canonical_path, status: 'preparing' }
}

fn goal_task_worktree_refuse_command_config(repository_root string) ! {
	git_directory := workspace_git_directory(repository_root)!
	common_directory := workspace_git_common_directory(repository_root)!
	mut config_paths := [os.join_path(common_directory, 'config')]
	worktree_config := os.join_path(git_directory, 'config.worktree')
	if os.exists(worktree_config) {
		config_paths << worktree_config
	}
	for config_path in config_paths {
		if os.is_link(config_path) {
			return error('goal task repository Git config must not be a symlink')
		}
		if !os.is_file(config_path) {
			return error('goal task repository Git config is missing or is not a regular file')
		}
		config := os.read_file(config_path)!
		mut section := ''
		for raw in config.split_into_lines() {
			line := raw.trim_space().to_lower()
			if !line.starts_with('[') {
				continue
			}
			section = line.trim_left('[').all_before(']').all_before(' ').all_before('"')
			for prefix in workspace_git_blocked_config_prefixes {
				if (section + '.').starts_with(prefix) {
					return error('goal task repository configures Git filters or includes that may execute commands')
				}
			}
		}
	}
}

fn (mut store Store) record_goal_task_worktree_intent(worktree GoalTaskWorktree,
	claim GoalTaskClaim) ! {
	store.mu.lock()
	defer { store.mu.unlock() }
	store.db.begin()!
	defer { store.db.rollback() or {} }
	rows := store.db.exec_param_many("SELECT a.status, a.session_operation_id, a.fencing_token, COALESCE(o.status, '') FROM goal_task_attempts AS a LEFT JOIN session_operations AS o ON o.session_id = a.session_id AND o.id = a.session_operation_id WHERE a.goal_id = ? AND a.task_id = ? AND a.attempt = ?", [
		worktree.goal_id,
		worktree.task_id,
		worktree.attempt.str(),
	])!
	if rows.len != 1 || rows[0].val(0) != 'running'
		|| rows[0].val(2) != claim.fencing_token
		|| (claim.session_operation_id.len > 0 && (rows[0].val(1) != claim.session_operation_id || rows[0].val(3) != 'running')) {
		return error('goal task attempt fencing check failed')
	}
	store.db.exec_param_many("INSERT INTO goal_task_attempt_workspaces (goal_id, task_id, attempt, repository_root, worktree_path, base_sha, status) VALUES (?, ?, ?, ?, ?, ?, 'preparing')", [
		worktree.goal_id,
		worktree.task_id,
		worktree.attempt.str(),
		worktree.repository_root,
		worktree.path,
		worktree.base_sha,
	])!
	store.db.commit()!
}

fn (mut store Store) classify_goal_task_worktree(worktree GoalTaskWorktree, claim GoalTaskClaim,
	status string) ! {
	if status !in ['ready', 'uncertain'] {
		return error('goal task worktree status is invalid')
	}
	store.mu.lock()
	defer { store.mu.unlock() }
	store.db.begin()!
	defer { store.db.rollback() or {} }
	rows := store.db.exec_param_many("SELECT a.status, a.session_operation_id, a.fencing_token, w.status, COALESCE(o.status, '') FROM goal_task_attempts AS a JOIN goal_task_attempt_workspaces AS w ON w.goal_id = a.goal_id AND w.task_id = a.task_id AND w.attempt = a.attempt LEFT JOIN session_operations AS o ON o.session_id = a.session_id AND o.id = a.session_operation_id WHERE a.goal_id = ? AND a.task_id = ? AND a.attempt = ?", [
		worktree.goal_id,
		worktree.task_id,
		worktree.attempt.str(),
	])!
	if rows.len != 1 || rows[0].val(0) != 'running'
		|| rows[0].val(2) != claim.fencing_token || rows[0].val(3) != 'preparing'
		|| (claim.session_operation_id.len > 0 && (rows[0].val(1) != claim.session_operation_id || (status == 'ready' && rows[0].val(4) != 'running'))) {
		return error('goal task worktree fencing check failed')
	}
	store.db.exec_param_many('UPDATE goal_task_attempt_workspaces SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE goal_id = ? AND task_id = ? AND attempt = ?', [
		status,
		worktree.goal_id,
		worktree.task_id,
		worktree.attempt.str(),
	])!
	store.db.commit()!
}
