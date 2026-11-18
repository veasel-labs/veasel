module main

import os
import time
import uuid

// Adversarial confinement tests. Everything lives in a unique temp dir; the
// race test only flips symlinks and never loops unbounded (fixed iteration
// count, helper thread stopped by a flag).

fn confinement_fixture() (string, string) {
	base := os.join_path(os.temp_dir(), 'veasel-confine-${uuid.new_v4().str()}')
	root := os.join_path(base, 'root')
	outside := os.join_path(base, 'outside')
	os.mkdir_all(os.join_path(root, 'sub')) or { panic(err) }
	os.mkdir_all(outside) or { panic(err) }
	os.write_file(os.join_path(outside, 'secret.txt'), 'TOP-SECRET\n') or { panic(err) }
	os.write_file(os.join_path(root, 'sub', 'f.txt'), 'inside\n') or { panic(err) }
	return os.real_path(root), os.real_path(outside)
}

fn confinement_cleanup(root string) {
	os.rmdir_all(os.dir(root)) or {}
}

fn confinement_edit(root string, relative string, content string) StoredWorkspaceEdit {
	draft := prepare_workspace_edit(root, relative, content) or { panic(err) }
	return StoredWorkspaceEdit{
		id:            uuid.new_v4().str()
		path:          draft.path
		expected_hash: draft.expected_hash
		content:       draft.content
		diff:          draft.diff
		create_file:   draft.create_file
		status:        'applying'
	}
}

fn test_leaf_symlink_is_rejected_for_edit_and_read() {
	$if windows {
		return
	}
	root, outside := confinement_fixture()
	defer { confinement_cleanup(root) }
	os.symlink(os.join_path(outside, 'secret.txt'), os.join_path(root, 'leaf-link')) or { panic(err) }
	if _ := resolve_workspace_edit_target(root, 'leaf-link') {
		assert false
	}
	// A direct read of the link path must not follow it.
	if content := read_workspace_text_file(os.join_path(root, 'leaf-link')) {
		assert content != 'TOP-SECRET\n'
		assert false
	}
}

fn test_parent_symlink_is_rejected_for_edit() {
	$if windows {
		return
	}
	root, outside := confinement_fixture()
	defer { confinement_cleanup(root) }
	os.symlink(outside, os.join_path(root, 'linked')) or { panic(err) }
	if _ := resolve_workspace_edit_target(root, 'linked/secret.txt') {
		assert false
	}
	if _ := prepare_workspace_edit(root, 'linked/new.txt', 'x\n') {
		assert false
	}
	assert !os.exists(os.join_path(outside, 'new.txt'))
}

fn test_hardlink_to_outside_file_is_rejected_for_edit_and_read() {
	$if windows {
		return
	}
	root, outside := confinement_fixture()
	defer { confinement_cleanup(root) }
	os.link(os.join_path(outside, 'secret.txt'), os.join_path(root, 'hard')) or { panic(err) }
	if _ := resolve_workspace_edit_target(root, 'hard') {
		assert false
	}
	if content := read_workspace_text_file(os.join_path(root, 'hard')) {
		assert content.len == 0
		assert false
	}
	assert os.read_file(os.join_path(outside, 'secret.txt')) or { panic(err) } == 'TOP-SECRET\n'
}

fn test_escaping_and_disguised_paths_are_rejected() {
	root, _ := confinement_fixture()
	defer { confinement_cleanup(root) }
	for dir in ['.git.', '.git ', 'GIT~1', 'NODE_MODULES'] {
		os.mkdir_all(os.join_path(root, dir)) or { panic(err) }
	}
	for bad in ['../outside/secret.txt', '/etc/passwd', 'sub/../../outside/x', 'sub//f.txt',
		'./sub/f.txt', 'sub\\..\\..\\outside\\x', '.GIT/config', '.Git/hooks/pre-commit', '.git./config',
		'.git /config', '.git::$INDEX_ALLOCATION/x', 'GIT~1/config', 'node_modules/x/y.js',
		'NODE_MODULES/x', 'sub/‮/x', 'sub/a\x00b'] {
		if target := resolve_workspace_edit_target(root, bad) {
			eprintln('unexpectedly accepted: ${bad} -> ${target}')
			assert false
		}
	}
	// Percent-encoding and fullwidth dots are ordinary file names, never
	// traversal; they must resolve strictly inside the root.
	for odd in ['%2e%2e/x', '%2e%2e%2fsecret', '．．/x', 'café.txt', 'CAFÉ.txt'] {
		target := resolve_workspace_edit_target(root, odd) or { continue }
		assert target.starts_with(root + os.path_separator)
	}
}

fn test_sensitive_names_are_classified() {
	for sensitive in ['.gitattributes', '.GITMODULES', '.husky/pre-commit', '.github/workflows/ci.yml',
		'sub/.envrc', '.git-hooks/pre-push', '.githooks/x', '.github./x', 'GITHUB~1/x'] {
		assert workspace_relative_path_is_sensitive(sensitive), sensitive
	}
	for plain in ['README.md', 'src/github.v', 'docs/gitattributes.md', '.gitignore'] {
		assert !workspace_relative_path_is_sensitive(plain), plain
	}
}

fn test_huge_and_sparse_files_are_bounded() {
	$if windows {
		return
	}
	root, _ := confinement_fixture()
	defer { confinement_cleanup(root) }
	big := os.join_path(root, 'big.txt')
	os.write_file(big, 'a'.repeat(max_workspace_edit_bytes + 10)) or { panic(err) }
	if _ := resolve_workspace_edit_target(root, 'big.txt') {
		assert false
	}
	if _ := read_workspace_text_file(big) {
		assert false
	}
	sparse := os.join_path(root, 'sparse.bin')
	mut file := os.create(sparse) or { panic(err) }
	file.write_to(u64(5) * 1024 * 1024 * 1024, [u8(1)]) or { panic(err) }
	file.close()
	if _ := read_workspace_text_file(sparse) {
		assert false
	}
}

fn test_edit_apply_replaces_in_place_and_keeps_mode() {
	$if windows {
		return
	}
	root, _ := confinement_fixture()
	defer { confinement_cleanup(root) }
	path := os.join_path(root, 'sub', 'f.txt')
	os.chmod(path, 0o640) or { panic(err) }
	edit := confinement_edit(root, 'sub/f.txt', 'changed\n')
	apply_workspace_edit(root, edit) or { panic(err) }
	assert os.read_file(path) or { panic(err) } == 'changed\n'
	assert int(os.stat(path) or { panic(err) }.mode & 0o777) == 0o640
	assert os.ls(os.join_path(root, 'sub')) or { panic(err) } == ['f.txt']
}

fn test_apply_refuses_hardlink_swapped_in_after_review() {
	$if windows {
		return
	}
	root, outside := confinement_fixture()
	defer { confinement_cleanup(root) }
	edit := confinement_edit(root, 'sub/f.txt', 'changed\n')
	os.rm(os.join_path(root, 'sub', 'f.txt')) or { panic(err) }
	os.link(os.join_path(outside, 'secret.txt'), os.join_path(root, 'sub', 'f.txt')) or { panic(err) }
	apply_workspace_edit(root, edit) or {
		assert os.read_file(os.join_path(outside, 'secret.txt')) or { panic(err) } == 'TOP-SECRET\n'
		return
	}
	assert false
}

fn test_pinned_parent_survives_symlink_swap_before_write() {
	$if windows {
		return
	}
	root, outside := confinement_fixture()
	defer { confinement_cleanup(root) }
	dirfd := confined_open_dir(root, ['sub']) or { panic(err) }
	defer { confined_close(dirfd) }
	// Swap the checked parent for a symlink to an outside directory AFTER the
	// descriptor is pinned. The write must still land in the original dir.
	os.rename(os.join_path(root, 'sub'), os.join_path(root, 'sub.orig')) or { panic(err) }
	os.symlink(outside, os.join_path(root, 'sub')) or { panic(err) }
	req := ConfinedReplace{
		root:          root
		leaf:          'f.txt'
		temporary:     '.veasel-edit-pin.tmp'
		content:       'PINNED\n'
		original:      'inside\n'
		expected_hash: workspace_content_hash('inside\n')
		existed:       true
		mode:          -1
	}
	confined_replace_in_dir(dirfd, req, confined_noop) or { panic(err) }
	assert os.read_file(os.join_path(root, 'sub.orig', 'f.txt')) or { panic(err) } == 'PINNED\n'
	assert !os.exists(os.join_path(outside, 'f.txt'))
	assert os.read_file(os.join_path(outside, 'secret.txt')) or { panic(err) } == 'TOP-SECRET\n'
}

fn test_post_write_verification_rolls_back_when_parent_leaves_the_root() {
	$if !linux {
		return
	}
	root, outside := confinement_fixture()
	defer { confinement_cleanup(root) }
	dirfd := confined_open_dir(root, ['sub']) or { panic(err) }
	defer { confined_close(dirfd) }
	source := os.join_path(root, 'sub')
	target := os.join_path(outside, 'moved')
	move_outside := fn [source, target] () {
		os.rename(source, target) or { panic(err) }
	}
	req := ConfinedReplace{
		root:          root
		leaf:          'f.txt'
		temporary:     '.veasel-edit-rb.tmp'
		content:       'EVIL\n'
		original:      'inside\n'
		expected_hash: workspace_content_hash('inside\n')
		existed:       true
		mode:          -1
	}
	confined_replace_in_dir(dirfd, req, move_outside) or {
		assert err.msg().contains('rolled back')
		assert os.read_file(os.join_path(outside, 'moved', 'f.txt')) or { panic(err) } == 'inside\n'
		return
	}
	assert false
}

fn confinement_flip_symlink(root string, outside string, stop_file string) {
	for !os.exists(stop_file) {
		os.rename(os.join_path(root, 'sub'), os.join_path(root, 'sub.hold')) or { continue }
		os.symlink(outside, os.join_path(root, 'sub')) or {}
		time.sleep(200 * time.microsecond)
		os.rm(os.join_path(root, 'sub')) or {}
		os.rename(os.join_path(root, 'sub.hold'), os.join_path(root, 'sub')) or {}
		time.sleep(200 * time.microsecond)
	}
}

fn test_symlink_swap_race_never_writes_outside() {
	$if windows {
		return
	}
	root, outside := confinement_fixture()
	defer { confinement_cleanup(root) }
	mut edits := []StoredWorkspaceEdit{}
	for i in 0 .. 300 {
		edits << confinement_edit(root, 'sub/n${i}.txt', 'RACE-WRITE-${i}\n')
	}
	stop_file := os.join_path(os.dir(root), 'stop')
	flipper := spawn confinement_flip_symlink(root, outside, stop_file)
	for edit in edits {
		apply_workspace_edit(root, edit) or {}
	}
	os.write_file(stop_file, 'stop') or { panic(err) }
	flipper.wait()
	// Every write either landed inside the real directory or was refused.
	assert os.ls(outside) or { panic(err) } == ['secret.txt']
	assert os.read_file(os.join_path(outside, 'secret.txt')) or { panic(err) } == 'TOP-SECRET\n'
}
