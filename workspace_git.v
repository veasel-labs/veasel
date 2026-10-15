module main

import os
import time

const max_workspace_git_worktrees = 64
const max_workspace_git_branch_len = 128
const max_workspace_git_worktree_path_len = 1024
const max_workspace_git_worktree_lock_reason_len = 256
const workspace_git_command_timeout = 30 * time.second

pub struct WorkspaceGitWorktree {
pub:
	path    string
	head    string @[omitempty]
	branch  string @[omitempty]
	locked  bool
	missing bool
	is_main bool @[json: 'is_main']
}

pub struct WorkspaceGitWorktreeCatalog {
pub:
	worktrees []WorkspaceGitWorktree
}

pub struct WorkspaceGitWorktreeAddInput {
pub:
	path       string
	branch     string @[omitempty]
	new_branch string @[json: 'new_branch'; omitempty]
	prune      bool
}

pub struct WorkspaceGitWorktreeRemoveInput {
pub:
	path  string
	force bool
}

pub struct WorkspaceGitWorktreeRemoval {
pub:
	removed string
	force   bool
}

pub struct WorkspaceGitWorktreeLockInput {
pub:
	path   string
	locked bool
	reason string @[omitempty]
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
			missing := os.is_link(worktree_path) || !os.is_dir(worktree_path)
			path := if missing {
				worktree_path.replace('\\', '/')
			} else {
				os.real_path(worktree_path)
			}
			head, branch := read_workspace_git_ref(entry_dir)
			worktrees << WorkspaceGitWorktree{
				path:    path
				head:    head
				branch:  branch
				locked:  workspace_git_worktree_locked(entry_dir)
				missing: missing
				is_main: false
			}
		}
	}
	return WorkspaceGitWorktreeCatalog{
		worktrees: worktrees
	}
}

fn workspace_git_main_checkout(root string) !string {
	common := workspace_git_common_directory(root)!
	return os.dir(common)
}

fn is_valid_workspace_git_branch_name(name string) bool {
	trimmed := name.trim_space()
	if trimmed.len == 0 || trimmed.len > max_workspace_git_branch_len {
		return false
	}
	if trimmed.starts_with('-') || trimmed.starts_with('.') || trimmed.ends_with('.')
		|| trimmed.ends_with('/') || trimmed.contains('..') || trimmed.contains('\\')
		|| trimmed.contains(' ') || trimmed.contains('\t') || trimmed.contains('\n')
		|| trimmed.contains('\0') || trimmed.contains('@{') || trimmed.contains('~')
		|| trimmed.contains('^') || trimmed.contains(':') || trimmed.contains('?')
		|| trimmed.contains('*') || trimmed.contains('[') {
		return false
	}
	for c in trimmed {
		if c.is_alnum() || c in [`_`, `-`, `/`, `.`, `+`] {
			continue
		}
		return false
	}
	return true
}

fn validate_workspace_git_worktree_path(path string) !string {
	trimmed := path.trim_space()
	if trimmed.len == 0 || trimmed.len > max_workspace_git_worktree_path_len {
		return error('worktree path is invalid')
	}
	if !os.is_abs_path(trimmed) {
		return error('worktree path must be absolute')
	}
	if trimmed.contains('\0') {
		return error('worktree path is invalid')
	}
	parent := os.dir(trimmed)
	if parent.len == 0 || os.is_link(parent) || !os.is_dir(parent) {
		return error('worktree parent directory must exist')
	}
	return os.real_path(parent).replace('\\', '/') + '/' + os.file_name(trimmed)
}

fn run_workspace_git_command(checkout string, args []string) !string {
	git := os.find_abs_path_of_executable('git') or {
		return error('git executable is not available')
	}
	mut process := os.new_process(git)
	process.set_args(args)
	process.set_work_folder(checkout)
	process.set_redirect_stdio()
	process.run()
	started := time.now()
	for process.is_alive() {
		if time.since(started) > workspace_git_command_timeout {
			process.signal_kill()
			process.close()
			return error('git worktree command timed out')
		}
		time.sleep(10 * time.millisecond)
	}
	process.wait()
	stdout := process.stdout_slurp().trim_space()
	stderr := process.stderr_slurp().trim_space()
	code := process.code
	process.close()
	if code != 0 {
		detail := if stderr.len > 0 { stderr } else { stdout }
		if detail.len == 0 {
			return error('git worktree command failed')
		}
		if detail.len > 512 {
			return error(detail[..512])
		}
		return error(detail)
	}
	return stdout
}

fn prune_workspace_git_worktrees(root string) !WorkspaceGitWorktreeCatalog {
	refuse_workspace_edit_while_git_locked(root)!
	checkout := workspace_git_main_checkout(root)!
	_ := run_workspace_git_command(checkout, ['worktree', 'prune'])!
	return list_workspace_git_worktrees(root)!
}

fn add_workspace_git_worktree(root string, input WorkspaceGitWorktreeAddInput) !WorkspaceGitWorktree {
	refuse_workspace_edit_while_git_locked(root)!
	checkout := workspace_git_main_checkout(root)!
	path := validate_workspace_git_worktree_path(input.path)!
	if os.exists(path) {
		return error('worktree path already exists')
	}
	catalog := list_workspace_git_worktrees(root)!
	if catalog.worktrees.len >= max_workspace_git_worktrees {
		return error('worktree limit (${max_workspace_git_worktrees}) reached')
	}
	mut args := ['worktree', 'add']
	new_branch := input.new_branch.trim_space()
	branch := input.branch.trim_space()
	if new_branch.len > 0 {
		if !is_valid_workspace_git_branch_name(new_branch) {
			return error('new_branch name is invalid')
		}
		args << '-b'
		args << new_branch
	}
	args << path
	if branch.len > 0 {
		if !is_valid_workspace_git_branch_name(branch) {
			return error('branch name is invalid')
		}
		args << branch
	} else if new_branch.len == 0 {
		return error('worktree add requires branch or new_branch')
	}
	_ := run_workspace_git_command(checkout, args)!
	updated := list_workspace_git_worktrees(root)!
	for entry in updated.worktrees {
		if entry.path == os.real_path(path) || entry.path == path {
			return entry
		}
	}
	return WorkspaceGitWorktree{
		path:    os.real_path(path)
		branch:  if new_branch.len > 0 { new_branch } else { branch }
		is_main: false
	}
}

fn remove_workspace_git_worktree(root string, input WorkspaceGitWorktreeRemoveInput) ! {
	refuse_workspace_edit_while_git_locked(root)!
	checkout := workspace_git_main_checkout(root)!
	path := validate_workspace_git_worktree_path(input.path)!
	resolved := os.real_path(path)
	catalog := list_workspace_git_worktrees(root)!
	mut found := false
	for entry in catalog.worktrees {
		if entry.is_main {
			continue
		}
		if entry.path == resolved || entry.path == path {
			found = true
			break
		}
	}
	if !found {
		return error('linked worktree not found')
	}
	mut args := ['worktree', 'remove']
	if input.force {
		args << '--force'
	}
	args << path
	_ := run_workspace_git_command(checkout, args)!
}

fn validate_workspace_git_worktree_lock_reason(reason string) !string {
	trimmed := reason.trim_space()
	if trimmed.len == 0 {
		return ''
	}
	if trimmed.len > max_workspace_git_worktree_lock_reason_len {
		return error('worktree lock reason is too long')
	}
	for c in trimmed {
		if c < 32 || c == 127 {
			return error('worktree lock reason is invalid')
		}
	}
	return trimmed
}

fn find_workspace_git_worktree(root string, path string) !WorkspaceGitWorktree {
	resolved := os.real_path(path)
	catalog := list_workspace_git_worktrees(root)!
	for entry in catalog.worktrees {
		if entry.path == resolved || entry.path == path {
			return entry
		}
	}
	return error('worktree not found')
}

fn set_workspace_git_worktree_locked(root string, input WorkspaceGitWorktreeLockInput) !WorkspaceGitWorktree {
	refuse_workspace_edit_while_git_locked(root)!
	checkout := workspace_git_main_checkout(root)!
	path := validate_workspace_git_worktree_path(input.path)!
	_ := find_workspace_git_worktree(root, path)!
	reason := validate_workspace_git_worktree_lock_reason(input.reason)!
	mut args := ['worktree']
	if input.locked {
		args << 'lock'
		if reason.len > 0 {
			args << '--reason'
			args << reason
		}
	} else {
		if reason.len > 0 {
			return error('worktree unlock does not accept a reason')
		}
		args << 'unlock'
	}
	args << path
	_ := run_workspace_git_command(checkout, args)!
	return find_workspace_git_worktree(root, path)!
}
