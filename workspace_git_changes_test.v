module main

import os
import uuid

fn changes_git(root string, args ...string) {
	mut argv := ['git', '-C', root]
	argv << args
	result := os.exec(argv)
	assert result.exit_code == 0
}

fn changes_test_repo() string {
	root := os.join_path(os.temp_dir(), 'veasel-git-changes-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	changes_git(root, 'init', '-q', '-b', 'main')
	changes_git(root, 'config', 'user.name', 't')
	changes_git(root, 'config', 'user.email', 't@example.invalid')
	changes_git(root, 'config', 'commit.gpgsign', 'false')
	os.write_file(os.join_path(root, 'a.txt'), 'one\n') or { panic(err) }
	changes_git(root, 'add', '.')
	changes_git(root, 'commit', '-q', '-m', 'init')
	return root
}

fn test_workspace_git_changes_lists_modified_and_untracked_and_diffs() {
	root := changes_test_repo()
	defer {
		os.rmdir_all(root) or {}
	}
	clean := workspace_git_changes(root) or { panic(err) }
	assert clean.changes.len == 0
	assert clean.branch == 'main'

	os.write_file(os.join_path(root, 'a.txt'), 'two\n') or { panic(err) }
	os.write_file(os.join_path(root, 'new.txt'), 'x\n') or { panic(err) }
	dirty := workspace_git_changes(root) or { panic(err) }
	assert dirty.changes.len == 2
	modified := dirty.changes.filter(it.path == 'a.txt')[0]
	assert modified.worktree == 'M'
	assert !modified.untracked
	assert dirty.changes.filter(it.path == 'new.txt')[0].untracked

	diff := workspace_git_diff(root, 'a.txt', false) or { panic(err) }
	assert diff.diff.contains('-one')
	assert diff.diff.contains('+two')
}

fn test_workspace_git_diff_rejects_unsafe_paths() {
	root := changes_test_repo()
	defer {
		os.rmdir_all(root) or {}
	}
	for bad in ['', '../x', '/etc/passwd', '--output=/tmp/x', 'a/../../b'] {
		workspace_git_diff(root, bad, false) or { continue }
		assert false, 'accepted ${bad}'
	}
}

fn test_workspace_git_changes_outside_a_repository_is_an_error() {
	root := os.join_path(os.temp_dir(), 'veasel-git-changes-none-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
	}
	workspace_git_changes(root) or { return }
	assert false, 'expected a non-repository error'
}
