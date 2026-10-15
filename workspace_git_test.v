module main

import os
import uuid

fn test_list_workspace_git_worktrees_includes_main_and_linked() {
	main_root := os.join_path(os.temp_dir(), 'veasel-git-list-main-${uuid.new_v4().str()}')
	worktree := os.join_path(os.temp_dir(), 'veasel-git-list-wt-${uuid.new_v4().str()}')
	git_common := os.join_path(main_root, '.git')
	gitdir := os.join_path(git_common, 'worktrees', 'feature')
	os.mkdir_all(gitdir) or { panic(err) }
	os.mkdir_all(worktree) or { panic(err) }
	defer {
		os.rmdir_all(main_root) or {}
		os.rmdir_all(worktree) or {}
	}
	os.write_file(os.join_path(git_common, 'HEAD'), 'ref: refs/heads/main\n') or { panic(err) }
	os.write_file(os.join_path(gitdir, 'HEAD'), 'ref: refs/heads/feature\n') or { panic(err) }
	os.write_file(os.join_path(gitdir, 'gitdir'), '${worktree}/.git\n') or { panic(err) }
	os.write_file(os.join_path(worktree, '.git'), 'gitdir: ${gitdir}\n') or { panic(err) }

	from_main := list_workspace_git_worktrees(main_root) or { panic(err) }
	assert from_main.worktrees.len == 2
	assert from_main.worktrees[0].is_main
	assert from_main.worktrees[0].path == os.real_path(main_root)
	assert from_main.worktrees[0].branch == 'main'
	assert from_main.worktrees[1].path == os.real_path(worktree)
	assert from_main.worktrees[1].branch == 'feature'
	assert !from_main.worktrees[1].is_main

	from_linked := list_workspace_git_worktrees(worktree) or { panic(err) }
	assert from_linked.worktrees.len == 2
	assert from_linked.worktrees.filter(it.is_main).len == 1
	assert from_linked.worktrees.filter(it.path == os.real_path(worktree)).len == 1
}

fn test_list_workspace_git_worktrees_marks_locks() {
	main_root := os.join_path(os.temp_dir(), 'veasel-git-list-lock-${uuid.new_v4().str()}')
	git_common := os.join_path(main_root, '.git')
	os.mkdir_all(git_common) or { panic(err) }
	defer {
		os.rmdir_all(main_root) or {}
	}
	os.write_file(os.join_path(git_common, 'HEAD'), 'ref: refs/heads/main\n') or { panic(err) }
	os.write_file(os.join_path(git_common, 'index.lock'), '') or { panic(err) }
	catalog := list_workspace_git_worktrees(main_root) or { panic(err) }
	assert catalog.worktrees.len == 1
	assert catalog.worktrees[0].locked
}

fn test_add_and_remove_workspace_git_worktree_via_git() {
	git := os.find_abs_path_of_executable('git') or { return }
	_ = git
	main_root := os.join_path(os.temp_dir(), 'veasel-git-wt-main-${uuid.new_v4().str()}')
	worktree := os.join_path(os.temp_dir(), 'veasel-git-wt-linked-${uuid.new_v4().str()}')
	os.mkdir_all(main_root) or { panic(err) }
	defer {
		os.rmdir_all(main_root) or {}
		os.rmdir_all(worktree) or {}
	}
	_ := run_workspace_git_command(main_root, ['init', '-b', 'main']) or { panic(err) }
	_ := run_workspace_git_command(main_root, ['config', 'user.email', 'veasel@example.com']) or {
		panic(err)
	}
	_ := run_workspace_git_command(main_root, ['config', 'user.name', 'Veasel']) or { panic(err) }
	os.write_file(os.join_path(main_root, 'README'), 'hello\n') or { panic(err) }
	_ := run_workspace_git_command(main_root, ['add', 'README']) or { panic(err) }
	_ := run_workspace_git_command(main_root, ['commit', '-m', 'init']) or { panic(err) }

	assert is_valid_workspace_git_branch_name('feature/demo')
	assert !is_valid_workspace_git_branch_name('-bad')
	assert !is_valid_workspace_git_branch_name('has space')

	created := add_workspace_git_worktree(main_root, WorkspaceGitWorktreeAddInput{
		path:       worktree
		new_branch: 'feature/demo'
	}) or { panic(err) }
	assert created.branch == 'feature/demo'
	assert !created.is_main
	assert os.is_dir(worktree)
	assert os.is_file(os.join_path(worktree, 'README'))

	listed := list_workspace_git_worktrees(main_root) or { panic(err) }
	assert listed.worktrees.len == 2

	remove_workspace_git_worktree(main_root, WorkspaceGitWorktreeRemoveInput{
		path:  worktree
		force: true
	}) or { panic(err) }
	after := list_workspace_git_worktrees(main_root) or { panic(err) }
	assert after.worktrees.len == 1
	assert after.worktrees[0].is_main
}
