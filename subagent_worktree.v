module main

import os
import time
import crypto.sha256

const max_subagent_untracked_list_bytes = 1024 * 1024
const max_subagent_untracked_files = 256
const max_subagent_untracked_file_bytes = 8 * 1024 * 1024
const max_subagent_untracked_total_bytes = 64 * 1024 * 1024

pub struct SubagentWorkspace {
pub:
	run_id      string
	path        string
	branch      string
	base_commit string
}

struct SubagentUntrackedFile {
	path       string
	sha256     string
	byte_count i64
}

// create_subagent_workspace creates a worktree from an immutable snapshot of
// the parent checkout. Git's stash-create path captures staged and unstaged
// tracked changes without changing the parent's index or files. Non-ignored
// untracked regular files are copied separately under explicit size bounds.
fn create_subagent_workspace(root string, data_directory string, run_id string) !SubagentWorkspace {
	if !valid_subagent_run_id(run_id) {
		return error('child agent run ID is invalid')
	}
	root_path := os.real_path(root)
	_ = workspace_git_common_directory(root_path)!
	data_path := os.real_path(data_directory)
	if !os.is_dir(data_path) {
		return error('child agent data directory must exist')
	}
	worktrees_directory := os.join_path(data_path, 'subagent-worktrees')
	if os.is_link(worktrees_directory) {
		return error('child agent worktree directory cannot be a symlink')
	}
	os.mkdir_all(worktrees_directory)!
	if os.is_link(worktrees_directory) {
		return error('child agent worktree directory cannot be a symlink')
	}
	main_checkout := workspace_git_main_checkout(root_path)!
	if subagent_path_is_within(main_checkout, os.real_path(worktrees_directory)) {
		return error('child agent worktrees must be outside the parent repository')
	}
	path := os.join_path(worktrees_directory, run_id)
	branch := 'veasel/subagents/${run_id}'
	if os.exists(path) {
		return error('child agent worktree path already exists')
	}
	status_before := run_workspace_git_command_output(root_path,
		['status', '--porcelain=v1', '-z', '--untracked-files=all'], 1024 * 1024)!
	base_commit := run_workspace_git_command(root_path, ['stash', 'create'])!
	resolved_commit := if base_commit.len > 0 {
		base_commit
	} else {
		run_workspace_git_command(root_path, ['rev-parse', '--verify', 'HEAD'])!
	}
	if !valid_git_object_id(resolved_commit) {
		return error('child agent snapshot did not produce a commit ID')
	}
	base_tree := run_workspace_git_command(root_path, ['rev-parse', '--verify',
		'${resolved_commit}^{tree}'])!
	untracked := subagent_untracked_files(root_path)!
	_ = add_subagent_worktree_from_commit(root_path, path, branch, resolved_commit)!
	copy_subagent_untracked_files(root_path, path, untracked) or {
		remove_workspace_git_worktree(root_path, WorkspaceGitWorktreeRemoveInput{
			path:  path
			force: true
		}) or {}
		checkout := workspace_git_main_checkout(root_path) or { '' }
		if checkout.len > 0 {
			_ := run_workspace_git_command(checkout, ['branch', '-D', branch]) or { '' }
		}
		return err
	}
	verify_subagent_untracked_files(root_path, untracked) or {
		remove_subagent_workspace(root_path, data_path, run_id, true) or {}
		return err
	}
	status_after := run_workspace_git_command_output(root_path,
		['status', '--porcelain=v1', '-z', '--untracked-files=all'], 1024 * 1024) or {
		remove_subagent_workspace(root_path, data_path, run_id, true) or {}
		return err
	}
	current_commit := run_workspace_git_command(root_path, ['stash', 'create']) or {
		remove_subagent_workspace(root_path, data_path, run_id, true) or {}
		return err
	}
	current_snapshot := if current_commit.len > 0 {
		current_commit
	} else {
		run_workspace_git_command(root_path, ['rev-parse', '--verify', 'HEAD']) or {
			remove_subagent_workspace(root_path, data_path, run_id, true) or {}
			return err
		}
	}
	current_tree := run_workspace_git_command(root_path,
		['rev-parse', '--verify', '${current_snapshot}^{tree}']) or {
		remove_subagent_workspace(root_path, data_path, run_id, true) or {}
		return err
	}
	if status_after != status_before || current_tree != base_tree {
		remove_subagent_workspace(root_path, data_path, run_id, true) or {}
		return error('parent checkout changed while the child workspace snapshot was prepared')
	}
	return SubagentWorkspace{
		run_id:      run_id
		path:        os.real_path(path)
		branch:      branch
		base_commit: resolved_commit
	}
}

// remove_subagent_workspace only removes the generated worktree and branch for
// this run. Dirty or committed child work is preserved unless discard_changes
// is explicitly true.
fn remove_subagent_workspace(root string, data_directory string, run_id string,
	discard_changes bool) ! {
	if !valid_subagent_run_id(run_id) {
		return error('child agent run ID is invalid')
	}
	data_path := os.real_path(data_directory)
	path := os.join_path(data_path, 'subagent-worktrees', run_id)
	branch := 'veasel/subagents/${run_id}'
	worktree := find_workspace_git_worktree(root, path)!
	if worktree.is_main || worktree.branch != branch {
		return error('child agent worktree does not match its run ID')
	}
	remove_workspace_git_worktree(root, WorkspaceGitWorktreeRemoveInput{
		path:  path
		force: discard_changes
	})!
	if discard_changes {
		checkout := workspace_git_main_checkout(root)!
		_ := run_workspace_git_command(checkout, ['branch', '-D', branch])!
	}
}

fn add_subagent_worktree_from_commit(root string, path string, branch string, commit string) !WorkspaceGitWorktree {
	if !is_valid_workspace_git_branch_name(branch) || !valid_git_object_id(commit) {
		return error('child agent worktree branch or snapshot is invalid')
	}
	refuse_workspace_edit_while_git_locked(root)!
	validated_path := validate_workspace_git_worktree_path(path)!
	if os.exists(validated_path) {
		return error('child agent worktree path already exists')
	}
	catalog := list_workspace_git_worktrees(root)!
	if catalog.worktrees.len >= max_workspace_git_worktrees {
		return error('worktree limit (${max_workspace_git_worktrees}) reached')
	}
	checkout := workspace_git_main_checkout(root)!
	_ := run_workspace_git_command(checkout, ['worktree', 'add', '-b', branch, validated_path,
		commit]) or {
		if os.exists(validated_path) {
			remove_workspace_git_worktree(root, WorkspaceGitWorktreeRemoveInput{
				path:  validated_path
				force: true
			}) or {}
		}
		return err
	}
	return find_workspace_git_worktree(root, validated_path) or {
		remove_workspace_git_worktree(root, WorkspaceGitWorktreeRemoveInput{
			path:  validated_path
			force: true
		}) or {}
		_ := run_workspace_git_command(checkout, ['branch', '-D', branch]) or { '' }
		return err
	}
}

fn subagent_untracked_files(root string) ![]SubagentUntrackedFile {
	listing := run_workspace_git_command_output(root, ['ls-files', '--others', '--exclude-standard',
		'-z'], max_subagent_untracked_list_bytes)!
	mut files := []SubagentUntrackedFile{}
	mut total_bytes := i64(0)
	for relative in listing.split('\0') {
		if relative.len == 0 {
			continue
		}
		validate_subagent_relative_path(relative)!
		source := subagent_source_file(root, relative)!
		file_bytes := os.file_size(source)
		if file_bytes > max_subagent_untracked_file_bytes {
			return error('untracked file exceeds the child workspace snapshot limit')
		}
		total_bytes += file_bytes
		if total_bytes > max_subagent_untracked_total_bytes {
			return error('untracked files exceed the child workspace snapshot limit')
		}
		files << SubagentUntrackedFile{
			path:       relative
			sha256:     sha256.sum(os.read_bytes(source)!).hex()
			byte_count: file_bytes
		}
		if files.len > max_subagent_untracked_files {
			return error('untracked file count exceeds the child workspace snapshot limit')
		}
	}
	return files
}

fn copy_subagent_untracked_files(root string, worktree string, files []SubagentUntrackedFile) ! {
	for file in files {
		relative := file.path
		validate_subagent_relative_path(relative)!
		source := subagent_source_file(root, relative) or {
			return error('untracked source changed while preparing the child workspace')
		}
		destination := os.join_path(worktree, relative)
		parts := relative.replace('\\', '/').split('/')
		ensure_subagent_directories(worktree, parts[..parts.len - 1])!
		if os.is_link(os.dir(destination)) || os.exists(destination) {
			return error('untracked path collides with a child workspace entry')
		}
		os.copy_file(source, destination)!
		if os.file_size(destination) != file.byte_count
			|| sha256.sum(os.read_bytes(destination)!).hex() != file.sha256
			|| sha256.sum(os.read_bytes(source)!).hex() != file.sha256 {
			return error('untracked source changed while preparing the child workspace')
		}
	}
}

fn verify_subagent_untracked_files(root string, files []SubagentUntrackedFile) ! {
	for file in files {
		source := subagent_source_file(root, file.path) or {
			return error('untracked source changed while preparing the child workspace')
		}
		if os.file_size(source) != file.byte_count
			|| sha256.sum(os.read_bytes(source)!).hex() != file.sha256 {
			return error('untracked source changed while preparing the child workspace')
		}
	}
}

fn subagent_source_file(root string, relative string) !string {
	validate_subagent_relative_path(relative)!
	mut path := root
	for component in relative.split('/') {
		path = os.join_path(path, component)
		if os.is_link(path) {
			return error('child workspace contains an unsupported untracked symlink')
		}
	}
	if !os.is_file(path) {
		return error('untracked source changed while preparing the child workspace')
	}
	return path
}

fn ensure_subagent_directories(root string, parts []string) ! {
	mut path := root
	for component in parts {
		path = os.join_path(path, component)
		if os.is_link(path) {
			return error('untracked path crosses a child workspace symlink')
		}
		if !os.exists(path) {
			os.mkdir(path) or {
				if !os.is_dir(path) || os.is_link(path) {
					return err
				}
			}
		}
		if os.is_link(path) || !os.is_dir(path) {
			return error('untracked path crosses a child workspace file')
		}
	}
}

fn subagent_path_is_within(parent string, child string) bool {
	mut canonical_parent := os.real_path(parent).replace('\\', '/').trim_right('/')
	mut canonical_child := os.real_path(child).replace('\\', '/').trim_right('/')
	$if windows {
		canonical_parent = canonical_parent.to_lower()
		canonical_child = canonical_child.to_lower()
	}
	return canonical_child == canonical_parent || canonical_child.starts_with(canonical_parent + '/')
}

fn run_workspace_git_command_output(checkout string, args []string, max_output_bytes int) !string {
	git := os.find_abs_path_of_executable('git') or {
		return error('git executable is not available')
	}
	mut process := os.new_process(git)
	process.set_args(args)
	process.set_work_folder(checkout)
	process.set_redirect_stdio()
	process.run()
	started := time.now()
	mut output := []u8{cap: 4096}
	for process.is_alive() {
		chunk := process.stdout_read()
		if chunk.len > 0 {
			if output.len + chunk.len > max_output_bytes {
				process.signal_kill()
				process.wait()
				process.close()
				return error('git worktree command output exceeds its size limit')
			}
			output << chunk.bytes()
		}
		if time.since(started) > workspace_git_command_timeout {
			process.signal_kill()
			process.wait()
			process.close()
			return error('git worktree command timed out')
		}
		time.sleep(10 * time.millisecond)
	}
	process.wait()
	tail := process.stdout_slurp()
	if output.len + tail.len > max_output_bytes {
		process.close()
		return error('git worktree command output exceeds its size limit')
	}
	output << tail.bytes()
	stderr := process.stderr_slurp().trim_space()
	code := process.code
	process.close()
	if code != 0 {
		if stderr.len == 0 {
			return error('git worktree command failed')
		}
		return error(if stderr.len > 512 { stderr[..512] } else { stderr })
	}
	return output.bytestr()
}

fn valid_subagent_run_id(value string) bool {
	if value.len != 36 {
		return false
	}
	for i, c in value {
		if i in [8, 13, 18, 23] {
			if c != `-` {
				return false
			}
		} else if !(c.is_digit() || c in [`a`, `b`, `c`, `d`, `e`, `f`]) {
			return false
		}
	}
	return true
}

fn valid_git_object_id(value string) bool {
	if value.len != 40 && value.len != 64 {
		return false
	}
	for c in value {
		if !(c.is_digit() || c in [`a`, `b`, `c`, `d`, `e`, `f`]) {
			return false
		}
	}
	return true
}

fn validate_subagent_relative_path(path string) ! {
	if path.len == 0 || path.len > 4096 || path.starts_with('/') || path.contains('\\')
		|| path.contains('\0') {
		return error('untracked path is invalid for a child workspace')
	}
	for component in path.split('/') {
		if component.len == 0 || component in ['.', '..'] {
			return error('untracked path is invalid for a child workspace')
		}
		for c in component {
			if c < 32 || c == 127 {
				return error('untracked path is invalid for a child workspace')
			}
		}
	}
}
