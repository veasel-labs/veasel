module main

import os
import uuid

// Windows-native confinement tests (#748). Junctions need no elevation,
// so they are the reliable reparse-point fixture on CI runners. Bodies are
// comptime-guarded: on other platforms these tests are empty, and the
// POSIX suite in workspace_confinement_test.v covers the same contract
// through descriptor-pinned opens.

fn win_conf_fixture() (string, string) {
	base := os.join_path(os.temp_dir(), 'veasel-conf-win-${uuid.new_v4().str()}')
	root := os.join_path(base, 'root')
	outside := os.join_path(base, 'outside')
	os.mkdir_all(os.join_path(root, 'sub')) or { panic(err) }
	os.mkdir_all(outside) or { panic(err) }
	os.write_file(os.join_path(outside, 'secret.txt'), 'TOP-SECRET\n') or { panic(err) }
	os.write_file(os.join_path(root, 'sub', 'f.txt'), 'inside\n') or { panic(err) }
	return os.real_path(root), os.real_path(outside)
}

fn win_conf_make_junction(link string, target string) {
	result := os.execute('cmd /c mklink /J "${link}" "${target}"')
	if result.exit_code != 0 {
		panic('mklink /J failed: ${result.output}')
	}
}

fn test_windows_junction_parent_is_rejected_for_edit() {
	$if windows {
		root, outside := win_conf_fixture()
		defer { os.rmdir_all(os.dir(root)) or {} }
		win_conf_make_junction(os.join_path(root, 'linked'), outside)
		assert confined_is_reparse_point(os.join_path(root, 'linked'))
		assert !confined_is_reparse_point(os.join_path(root, 'sub'))
		assert !confined_is_reparse_point(os.join_path(root, 'sub', 'f.txt'))
		if _ := confined_verify_target(root, ['linked', 'secret.txt']) {
			assert false, 'junction parent must be rejected'
		}
		if _ := resolve_workspace_edit_target(root, 'linked/secret.txt') {
			assert false, 'edit target through a junction must be rejected'
		}
		if _ := prepare_workspace_edit(root, 'linked/new.txt', 'x\n') {
			assert false, 'edit creation through a junction must be rejected'
		}
		assert !os.exists(os.join_path(outside, 'new.txt'))
		assert os.read_file(os.join_path(outside, 'secret.txt')) or { panic(err) } == 'TOP-SECRET\n'
	}
}

fn test_windows_normal_tree_still_edits_and_reads() {
	$if windows {
		root, _ := win_conf_fixture()
		defer { os.rmdir_all(os.dir(root)) or {} }
		confined_verify_target(root, ['sub', 'f.txt']) or { panic(err) }
		assert read_workspace_text_file(os.join_path(root, 'sub', 'f.txt')) or {
			panic(err)
		} == 'inside\n'
		draft := prepare_workspace_edit(root, 'sub/f.txt', 'changed\n') or { panic(err) }
		apply_workspace_edit(root, StoredWorkspaceEdit{
			id:            uuid.new_v4().str()
			path:          draft.path
			expected_hash: draft.expected_hash
			content:       draft.content
			diff:          draft.diff
			create_file:   draft.create_file
			status:        'applying'
		}) or { panic(err) }
		assert os.read_file(os.join_path(root, 'sub', 'f.txt')) or { panic(err) } == 'changed\n'
	}
}
