module main

import os
import time

// GoalTaskCandidateObservation is a point-in-time observation of a committed
// candidate in an isolated task worktree. It is deliberately not a receipt:
// callers still need an independent verifier identity and a durable evidence
// transaction before a task can become succeeded.
pub struct GoalTaskCandidateObservation {
pub:
	base_sha      string
	candidate_sha string
	changed_paths []string
}

// observe_goal_task_candidate verifies only repository facts that Veasel can
// observe locally. It never runs tests, executes repository code, mutates Git,
// persists evidence, or changes Goal state.
fn observe_goal_task_candidate(worktree GoalTaskWorktree, task GoalTask,
	candidate_sha string, deadline time.Time) !GoalTaskCandidateObservation {
	if worktree.status != 'ready' || worktree.attempt <= 0 || worktree.path.trim_space() == '' {
		return error('goal task candidate requires a ready worktree')
	}
	if !valid_goal_sha(candidate_sha) || !valid_goal_sha(worktree.base_sha)
		|| candidate_sha == worktree.base_sha || task.base_sha != worktree.base_sha {
		return error('goal task candidate SHA does not identify a non-base full commit')
	}
	if !os.is_abs_path(worktree.path) || os.is_link(worktree.path) || !os.is_dir(worktree.path) {
		return error('goal task candidate worktree is not a canonical directory')
	}
	canonical_path := os.real_path(worktree.path)
	if !goal_candidate_paths_equal(canonical_path, worktree.path) {
		return error('goal task candidate worktree is not canonical')
	}
	if !os.is_abs_path(worktree.repository_root) || os.is_link(worktree.repository_root)
		|| !os.is_dir(worktree.repository_root) {
		return error('goal task candidate repository root is not a canonical directory')
	}
	canonical_repository_root := os.real_path(worktree.repository_root)
	if !goal_candidate_paths_equal(canonical_repository_root, worktree.repository_root) {
		return error('goal task candidate repository root is not canonical')
	}
	if goal_task_path_is_within(canonical_repository_root, canonical_path) {
		return error('goal task candidate worktree is not isolated')
	}
	for path in task.paths {
		if !valid_goal_relative_path(path) || workspace_has_hidden_controls(path) {
			return error('goal task candidate scope contains an invalid path')
		}
	}
	root := run_goal_git_command_output_until(canonical_path,
		['--no-replace-objects', 'rev-parse', '--show-toplevel'], max_goal_git_output_bytes,
		deadline) or { return error('unable to inspect goal task candidate worktree') }
	if !goal_candidate_paths_equal(os.real_path(root.trim_space()), canonical_path) {
		return error('goal task candidate worktree Git root does not match the persisted path')
	}
	resolved := run_goal_git_command_output_until(canonical_path,
		['--no-replace-objects', 'rev-parse', '--verify', '--end-of-options',
			'${candidate_sha}^{commit}'], max_goal_git_output_bytes, deadline) or {
		return error('goal task candidate commit does not exist')
	}
	if resolved.trim_space() != candidate_sha {
		return error('goal task candidate commit did not resolve to the exact full SHA')
	}
	first_head := goal_candidate_head(canonical_path, deadline)!
	if first_head != candidate_sha {
		return error('goal task candidate worktree HEAD does not match the requested SHA')
	}
	_ := run_goal_git_command_output_until(canonical_path,
		['--no-replace-objects', 'merge-base', '--is-ancestor', worktree.base_sha, candidate_sha], max_goal_git_output_bytes, deadline) or {
		return error('goal task candidate is not descended from the admitted base SHA')
	}
	changed_paths := goal_candidate_changed_paths(canonical_path, worktree.base_sha,
		candidate_sha, deadline)!
	for path in changed_paths {
		if !goal_candidate_path_in_scope(path, task.paths) {
			return error('goal task candidate changes path outside the admitted scope: ${path}')
		}
		goal_candidate_tree_path_is_safe(canonical_path, candidate_sha, path, deadline)!
	}
	first_status := goal_candidate_worktree_status(canonical_path, deadline)!
	if first_status.len != 0 {
		return error('goal task candidate worktree is dirty')
	}
	second_head := goal_candidate_head(canonical_path, deadline)!
	second_status := goal_candidate_worktree_status(canonical_path, deadline)!
	if second_head != first_head || second_status.len != 0 {
		return error('goal task candidate worktree changed during observation')
	}
	return GoalTaskCandidateObservation{
		base_sha:      worktree.base_sha
		candidate_sha: candidate_sha
		changed_paths: changed_paths
	}
}

fn goal_candidate_paths_equal(left string, right string) bool {
	return goal_task_path_is_within(left, right) && goal_task_path_is_within(right, left)
}

// goal_candidate_tree_path_is_safe checks every tree prefix for the candidate
// commit. A changed path name alone is insufficient: a candidate can replace a
// scoped file or directory with a symlink or gitlink and thereby escape the
// admitted scope for later consumers.
fn goal_candidate_tree_path_is_safe(worktree_path string, candidate_sha string, path string,
	deadline time.Time) ! {
	mut prefix := ''
	segments := path.split('/')
	for index, segment in segments {
		prefix = if prefix.len == 0 { segment } else { '${prefix}/${segment}' }
		entry_output := run_goal_git_command_output_until(worktree_path,
			['--no-replace-objects', 'ls-tree', '-z', candidate_sha, '--', ':(literal)${prefix}'], max_goal_git_output_bytes, deadline)!
		if entry_output.len == 0 {
			break
		}
		entry := entry_output.split('\0')[0]
		tab := entry.index('\t') or { return error('candidate Git tree entry is malformed') }
		metadata := entry[..tab].split(' ')
		if metadata.len < 2 {
			return error('candidate Git tree entry is malformed')
		}
		if metadata[0] in ['120000', '160000'] {
			return error('goal task candidate scope contains a symlink or gitlink')
		}
		if index < segments.len - 1 && metadata[1] != 'tree' {
			return error('candidate Git tree path parent is not a directory')
		}
	}
}

fn goal_candidate_head(worktree_path string, deadline time.Time) !string {
	head := run_goal_git_command_output_until(worktree_path,
		['--no-replace-objects', 'rev-parse', '--verify', '--end-of-options', 'HEAD'],
		max_goal_git_output_bytes, deadline)!
	return head.trim_space()
}

fn goal_candidate_worktree_status(worktree_path string, deadline time.Time) !string {
	return run_goal_git_command_output_until(worktree_path,
		['--no-replace-objects', 'status', '--porcelain=v1', '--untracked-files=all'],
		max_goal_git_output_bytes, deadline)
}

fn goal_candidate_changed_paths(worktree_path string, base_sha string, candidate_sha string,
	deadline time.Time) ![]string {
	raw := run_goal_git_command_output_until(worktree_path,
		['--no-replace-objects', 'diff', '--no-ext-diff', '--no-textconv', '--name-only', '-z',
			'--no-renames', base_sha, candidate_sha, '--'], max_goal_git_output_bytes, deadline)!
	mut paths := []string{}
	for path in raw.split('\0') {
		if path.len == 0 {
			continue
		}
		if !valid_goal_relative_path(path) || workspace_has_hidden_controls(path) {
			return error('goal task candidate diff contains an invalid path')
		}
		paths << path
	}
	return paths
}

fn goal_candidate_path_in_scope(path string, scopes []string) bool {
	for scope in scopes {
		if path == scope || path.starts_with(scope + '/') {
			return true
		}
	}
	return false
}
