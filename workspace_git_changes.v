module main

import os

// Read-only working-tree view for a session's directory (Focus "Changes"). It answers the
// question "what did the agent change?" from the repository itself. It reuses the confined
// git runner from workspace_git.v and never writes: no stage, commit, or checkout here.

const max_workspace_git_diff_bytes = 262_144
const max_workspace_git_changes = 500

pub struct WorkspaceGitChange {
pub:
	path      string
	index     string // porcelain X column: staged state, ' ' when unchanged
	worktree  string // porcelain Y column: working-tree state, ' ' when unchanged
	untracked bool
}

pub struct WorkspaceGitChanges {
pub:
	branch    string @[omitempty]
	changes   []WorkspaceGitChange
	truncated bool
}

pub struct WorkspaceGitDiff {
pub:
	path      string
	staged    bool
	diff      string
	truncated bool
}

// workspace_git_changes lists changed, staged and untracked paths with plain `git status`.
fn workspace_git_changes(root string) !WorkspaceGitChanges {
	out := run_workspace_git_command(root, ['-c', 'core.fsmonitor=false', 'status', '--porcelain=v1',
		'-z', '--branch', '--no-renames', '--untracked-files=all'])!
	mut branch := ''
	mut changes := []WorkspaceGitChange{}
	mut truncated := false
	for entry in out.split('\0') {
		if entry.len == 0 {
			continue
		}
		if entry.starts_with('## ') {
			branch = entry[3..].all_before('...').all_before(' ')
			continue
		}
		if entry.len < 4 {
			continue
		}
		if changes.len >= max_workspace_git_changes {
			truncated = true
			break
		}
		changes << WorkspaceGitChange{
			path:      entry[3..]
			index:     entry[..1]
			worktree:  entry[1..2]
			untracked: entry.starts_with('??')
		}
	}
	return WorkspaceGitChanges{
		branch:    branch
		changes:   changes
		truncated: truncated
	}
}

fn validate_workspace_git_diff_path(path string) !string {
	if path.len == 0 || path.len > 4_096 || path.starts_with('-') || os.is_abs_path(path)
		|| path.contains('\x00') {
		return error('diff path must be a non-empty relative path')
	}
	for segment in path.replace('\\', '/').split('/') {
		if segment == '..' {
			return error('diff path must not leave the selected root')
		}
	}
	return path
}

// workspace_git_diff returns the unified diff of one path, never running external diff
// drivers or text converters configured in the repository.
fn workspace_git_diff(root string, path string, staged bool) !WorkspaceGitDiff {
	safe := validate_workspace_git_diff_path(path)!
	mut args := ['-c', 'core.fsmonitor=false', 'diff', '--no-ext-diff', '--no-textconv', '--no-color',
		'--no-renames']
	if staged {
		args << '--cached'
	}
	args << '--'
	args << safe
	out := run_workspace_git_command(root, args)!
	truncated := out.len > max_workspace_git_diff_bytes
	return WorkspaceGitDiff{
		path:      safe
		staged:    staged
		diff:      if truncated { out[..max_workspace_git_diff_bytes] } else { out }
		truncated: truncated
	}
}
