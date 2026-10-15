module main

import os

const max_workspace_git_worktrees = 64

pub struct WorkspaceGitWorktree {
pub:
	path    string
	head    string @[omitempty]
	branch  string @[omitempty]
	locked  bool
	is_main bool @[json: 'is_main']
}

pub struct WorkspaceGitWorktreeCatalog {
pub:
	worktrees []WorkspaceGitWorktree
}

// workspace_git_common_directory returns the shared git directory that owns
// worktrees/<id> entries. For the primary checkout this is `<root>/.git`. For a
// linked worktree it is the parent of `worktrees/` above the linked gitdir.
fn workspace_git_common_directory(root string) !string {
	git_directory := workspace_git_directory(root)!
	normalized := git_directory.replace('\\', '/')
	marker := '/worktrees/'
	idx := normalized.last_index(marker) or { -1 }
	if idx >= 0 {
		parent := normalized[..idx]
		if parent.len == 0 {
			return error('unable to resolve common git directory')
		}
		$if windows {
			return os.real_path(parent.replace('/', '\\'))
		} $else {
			return os.real_path(parent)
		}
	}
	return git_directory
}

fn read_workspace_git_ref(git_directory string) (string, string) {
	head_path := os.join_path(git_directory, 'HEAD')
	raw := os.read_file(head_path) or { return '', '' }
	trimmed := raw.trim_space()
	if trimmed.starts_with('ref: ') {
		reference := trimmed[5..].trim_space()
		branch := if reference.starts_with('refs/heads/') {
			reference[11..]
		} else {
			''
		}
		return reference, branch
	}
	return trimmed, ''
}

fn workspace_git_worktree_locked(git_directory string) bool {
	for name in workspace_git_lock_names {
		if os.exists(os.join_path(git_directory, name)) {
			return true
		}
	}
	return os.exists(os.join_path(git_directory, 'locked'))
}

fn list_workspace_git_worktrees(root string) !WorkspaceGitWorktreeCatalog {
	common := workspace_git_common_directory(root)!
	mut worktrees := []WorkspaceGitWorktree{cap: max_workspace_git_worktrees}
	main_path := os.dir(common)
	main_head, main_branch := read_workspace_git_ref(common)
	worktrees << WorkspaceGitWorktree{
		path:    main_path
		head:    main_head
		branch:  main_branch
		locked:  workspace_git_worktree_locked(common)
		is_main: true
	}
	worktrees_root := os.join_path(common, 'worktrees')
	if os.is_dir(worktrees_root) && !os.is_link(worktrees_root) {
		entries := os.ls(worktrees_root) or { []string{} }
		mut sorted := entries.clone()
		sorted.sort()
		for entry in sorted {
			if worktrees.len >= max_workspace_git_worktrees {
				break
			}
			if entry == '.' || entry == '..' {
				continue
			}
			entry_dir := os.join_path(worktrees_root, entry)
			if os.is_link(entry_dir) || !os.is_dir(entry_dir) {
				continue
			}
			gitdir_pointer := os.join_path(entry_dir, 'gitdir')
			if !os.is_file(gitdir_pointer) || os.is_link(gitdir_pointer) {
				continue
			}
			pointer := os.read_file(gitdir_pointer) or { continue }
			mut worktree_git_file := pointer.trim_space()
			if worktree_git_file.len == 0 {
				continue
			}
			if !os.is_abs_path(worktree_git_file) {
				worktree_git_file = os.join_path(entry_dir, worktree_git_file)
			}
			if os.is_link(worktree_git_file) {
				continue
			}
			worktree_path := os.dir(worktree_git_file)
			if !os.is_dir(worktree_path) || os.is_link(worktree_path) {
				continue
			}
			head, branch := read_workspace_git_ref(entry_dir)
			worktrees << WorkspaceGitWorktree{
				path:    os.real_path(worktree_path)
				head:    head
				branch:  branch
				locked:  workspace_git_worktree_locked(entry_dir)
				is_main: false
			}
		}
	}
	return WorkspaceGitWorktreeCatalog{
		worktrees: worktrees
	}
}
