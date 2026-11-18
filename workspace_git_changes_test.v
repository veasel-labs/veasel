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

// --- Untrusted repository fixtures: showing Changes must never run code the repository configures. ---

fn malicious_marker(root string, name string) string {
	return os.join_path(os.dir(root), '${os.file_name(root)}-${name}.marker')
}

fn malicious_script(root string, name string) string {
	script := os.join_path(os.dir(root), '${os.file_name(root)}-${name}.sh')
	marker := malicious_marker(root, name)
	os.write_file(script, '#!/bin/sh\ntouch "${marker}"\ncat\n') or { panic(err) }
	os.chmod(script, 0o755) or { panic(err) }
	return script
}

fn append_git_config(root string, text string) {
	path := os.join_path(root, '.git', 'config')
	existing := os.read_file(path) or { '' }
	os.write_file(path, existing + text) or { panic(err) }
}

fn cleanup_malicious(root string, names []string) {
	for name in names {
		os.rm(malicious_marker(root, name)) or {}
		os.rm(os.join_path(os.dir(root), '${os.file_name(root)}-${name}.sh')) or {}
	}
	os.rmdir_all(root) or {}
}

fn dirty_tracked_file(root string) {
	// Different size, so git must read the content (and run any clean filter) to know it changed.
	os.write_file(os.join_path(root, 'a.txt'), 'changed content that is longer\n') or { panic(err) }
}

fn test_fsmonitor_from_repository_config_is_never_run() {
	root := changes_test_repo()
	defer { cleanup_malicious(root, ['fsm']) }
	append_git_config(root, '[core]\n\tfsmonitor = ${malicious_script(root, 'fsm')}\n')
	dirty_tracked_file(root)
	workspace_git_changes(root) or {}
	assert !os.exists(malicious_marker(root, 'fsm'))
}

fn test_external_diff_and_textconv_from_repository_config_are_never_run() {
	root := changes_test_repo()
	defer { cleanup_malicious(root, ['ext', 'conv']) }
	append_git_config(root, '[diff]\n\texternal = ${malicious_script(root, 'ext')}\n[diff "evil"]\n\ttextconv = ${malicious_script(root, 'conv')}\n\tcommand = ${malicious_script(root, 'ext')}\n')
	os.write_file(os.join_path(root, '.gitattributes'), '*.txt diff=evil\n') or { panic(err) }
	dirty_tracked_file(root)
	workspace_git_diff(root, 'a.txt', false) or {}
	workspace_git_changes(root) or {}
	assert !os.exists(malicious_marker(root, 'ext'))
	assert !os.exists(malicious_marker(root, 'conv'))
}

fn test_clean_filter_from_repository_config_is_never_run() {
	root := changes_test_repo()
	defer { cleanup_malicious(root, ['flt']) }
	append_git_config(root, '[filter "evil"]\n\tclean = ${malicious_script(root, 'flt')}\n')
	os.write_file(os.join_path(root, '.gitattributes'), '*.txt filter=evil\n') or { panic(err) }
	dirty_tracked_file(root)
	workspace_git_changes(root) or {}
	workspace_git_diff(root, 'a.txt', false) or {}
	assert !os.exists(malicious_marker(root, 'flt'))
}

fn test_included_config_cannot_smuggle_a_filter() {
	root := changes_test_repo()
	defer { cleanup_malicious(root, ['inc']) }
	included := os.join_path(os.dir(root), '${os.file_name(root)}-inc.cfg')
	defer { os.rm(included) or {} }
	os.write_file(included, '[filter "evil"]\n\tclean = ${malicious_script(root, 'inc')}\n') or { panic(err) }
	append_git_config(root, '[include]\n\tpath = ${included}\n')
	os.write_file(os.join_path(root, '.gitattributes'), '*.txt filter=evil\n') or { panic(err) }
	dirty_tracked_file(root)
	workspace_git_changes(root) or {}
	assert !os.exists(malicious_marker(root, 'inc'))
}

fn test_symlinked_git_directory_is_refused() {
	root := changes_test_repo()
	outside := os.join_path(os.dir(root), '${os.file_name(root)}-outside')
	defer {
		os.rmdir_all(outside) or {}
		cleanup_malicious(root, ['sym'])
	}
	os.mv(os.join_path(root, '.git'), outside) or { panic(err) }
	os.symlink(outside, os.join_path(root, '.git')) or { panic(err) }
	workspace_git_changes(root) or { return }
	assert false, 'a symlinked .git must be refused'
}

fn test_a_subdirectory_of_a_repository_is_refused() {
	root := changes_test_repo()
	defer { cleanup_malicious(root, []) }
	sub := os.join_path(root, 'src')
	os.mkdir_all(sub) or { panic(err) }
	workspace_git_changes(sub) or { return }
	assert false, 'a session directory that is not the repository top level must be refused'
}

fn test_huge_diff_is_truncated_and_returns() {
	root := changes_test_repo()
	defer { cleanup_malicious(root, []) }
	os.write_file(os.join_path(root, 'a.txt'), 'x'.repeat(3_000_000) + '\n') or { panic(err) }
	diff := workspace_git_diff(root, 'a.txt', false) or { panic(err) }
	assert diff.truncated
	assert diff.diff.len <= max_workspace_git_diff_bytes + 64
}
