module main

import os
import uuid

fn test_workspace_file_tools_bound_paths_and_skip_symlinks() {
	root := os.join_path(os.temp_dir(), 'veasel-workspace-${uuid.new_v4().str()}')
	external := os.join_path(os.temp_dir(), 'veasel-workspace-external-${uuid.new_v4().str()}')
	os.mkdir_all(os.join_path(root, 'src')) or { panic(err) }
	os.mkdir_all(os.join_path(root, '.git', 'objects')) or { panic(err) }
	os.mkdir_all(os.join_path(root, 'node_modules', 'fixture')) or { panic(err) }
	os.mkdir_all(external) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
		os.rmdir_all(external) or {}
	}
	os.write_file(os.join_path(root, 'README.md'), 'Veasel workspace fixture\n') or { panic(err) }
	os.write_file(os.join_path(root, 'src', 'main.v'), 'module example\nfn main() {}\n') or {
		panic(err)
	}
	os.write_file(os.join_path(root, '.git', 'objects', 'secret'), 'ignored git object') or {
		panic(err)
	}
	os.write_file(os.join_path(root, 'node_modules', 'fixture', 'secret.js'), 'ignored dependency') or {
		panic(err)
	}
	os.write_file(os.join_path(external, 'secret.txt'), 'outside workspace') or { panic(err) }
	os.symlink(external, os.join_path(root, 'outside-link')) or { panic(err) }
	os.symlink(os.join_path(root, 'src', 'main.v'), os.join_path(root, 'src-link.v')) or {
		panic(err)
	}
	files := workspace_files(root, max_workspace_list_results) or { panic(err) }
	assert files.files == ['README.md', 'src/main.v']
	assert !files.truncated
	limited_files := workspace_files(root, 1) or { panic(err) }
	assert limited_files.files == ['README.md']
	assert limited_files.truncated
	assert workspace_files_error_contains(root, 0, 'listing limit')
	assert workspace_file(root, 'src/main.v') or { panic(err) } == WorkspaceFileContent{
		path:    'src/main.v'
		content: 'module example\nfn main() {}\n'
	}
	assert workspace_file_error_contains(root, '../outside-link/secret.txt', 'must not leave')
	assert workspace_file_error_contains(root, 'outside-link/secret.txt', 'escapes')
}

fn test_workspace_search_is_literal_bounded_and_skips_binary_files() {
	root := os.join_path(os.temp_dir(), 'veasel-workspace-search-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	os.write_file(os.join_path(root, 'one.txt'), 'alpha\nneedle in one\n') or { panic(err) }
	os.write_file(os.join_path(root, 'two.txt'), 'needle in two\n') or { panic(err) }
	os.write_file(os.join_path(root, 'binary.dat'), 'skip\x00needle') or { panic(err) }
	os.write_file(os.join_path(root, 'invalid-utf8.dat'), '\xff') or { panic(err) }
	result := workspace_search(root, 'needle') or { panic(err) }
	assert result.matches.len == 2
	assert result.matches[0] == WorkspaceSearchMatch{
		path: 'one.txt'
		line: 2
		text: 'needle in one'
	}
	assert result.matches[1].path == 'two.txt'
	assert result.matches[1].line == 1
	assert !result.truncated
	assert workspace_file_error_contains(root, 'binary.dat', 'binary files')
	assert workspace_file_error_contains(root, 'invalid-utf8.dat', 'UTF-8')
	assert workspace_search_error_contains(root, '   ', 'search query')
	assert workspace_search_error_contains(root, 'x'.repeat(max_workspace_query_bytes + 1),
		'search query')
}

fn test_workspace_edit_is_diffed_confined_and_stale_safe() {
	root := os.join_path(os.temp_dir(), 'veasel-workspace-edit-${uuid.new_v4().str()}')
	external := os.join_path(os.temp_dir(), 'veasel-workspace-edit-external-${uuid.new_v4().str()}')
	os.mkdir_all(os.join_path(root, 'src')) or { panic(err) }
	os.mkdir_all(external) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
		os.rmdir_all(external) or {}
	}
	path := os.join_path(root, 'src', 'main.v')
	os.write_file(path, 'module fixture\nfn main() {}\n') or { panic(err) }
	$if !windows {
		os.chmod(path, 0o640) or { panic(err) }
	}
	os.write_file(os.join_path(external, 'secret'), 'outside') or { panic(err) }
	os.symlink(external, os.join_path(root, 'linked')) or { panic(err) }
	draft := prepare_workspace_edit(root, 'src/main.v', 'module fixture\nfn main() { println(1) }\n') or {
		panic(err)
	}
	assert draft.diff.contains('-fn main() {}')
	assert draft.diff.contains('+fn main() { println(1) }')
	assert !draft.create_file
	assert draft.expected_hash == workspace_content_hash('module fixture\nfn main() {}\n')
	new_draft := prepare_workspace_edit(root, 'src/new.v', 'module fixture\n') or { panic(err) }
	assert new_draft.create_file
	assert new_draft.diff.contains('+module fixture')
	newline_draft := prepare_workspace_edit(root, 'src/main.v', 'module fixture\nfn main() {}') or {
		panic(err)
	}
	assert newline_draft.diff.contains('Line ending changes:')
	assert newline_draft.diff.contains('- line 2: LF')
	assert newline_draft.diff.contains('+ line 2: no line ending')
	crlf_draft := prepare_workspace_edit(root, 'src/main.v', 'module fixture\r\nfn main() {}\r\n') or {
		panic(err)
	}
	assert crlf_draft.diff.contains('- line 1: LF')
	assert crlf_draft.diff.contains('+ line 1: CRLF')
	assert workspace_edit_rejected(root, '../outside.txt')
	assert workspace_edit_rejected(root, 'linked/secret')
	assert workspace_edit_rejected(root, '.git/config')
	assert workspace_edit_rejected(root, 'src/hidden\x1b[31m.v')
	assert workspace_edit_content_rejected(root, 'src/main.v', 'module fixture\n\x1b[31mfn main() {}\n')

	edit := StoredWorkspaceEdit{
		id:            uuid.new_v4().str()
		path:          draft.path
		expected_hash: draft.expected_hash
		content:       draft.content
		diff:          draft.diff
		status:        'applying'
	}
	apply_workspace_edit(root, edit) or { panic(err) }
	assert os.read_file(path) or { panic(err) } == draft.content
	$if !windows {
		info := os.stat(path) or { panic(err) }
		assert int(info.mode & 0o777) == 0o640
	}
	stale := StoredWorkspaceEdit{
		id:            uuid.new_v4().str()
		path:          draft.path
		expected_hash: draft.expected_hash
		content:       'stale write\n'
		diff:          ''
		status:        'applying'
	}
	assert workspace_edit_apply_rejected(root, stale)
}

fn workspace_file_error_contains(root string, path string, expected string) bool {
	_ := workspace_file(root, path) or { return err.msg().contains(expected) }
	return false
}

fn workspace_files_error_contains(root string, limit int, expected string) bool {
	_ := workspace_files(root, limit) or { return err.msg().contains(expected) }
	return false
}

fn workspace_search_error_contains(root string, query string, expected string) bool {
	_ := workspace_search(root, query) or { return err.msg().contains(expected) }
	return false
}

fn workspace_edit_rejected(root string, path string) bool {
	_ := prepare_workspace_edit(root, path, 'proposed content\n') or { return true }
	return false
}

fn workspace_edit_apply_rejected(root string, edit StoredWorkspaceEdit) bool {
	apply_workspace_edit(root, edit) or { return err.msg().contains('changed after review') }
	return false
}

fn workspace_edit_content_rejected(root string, path string, content string) bool {
	_ := prepare_workspace_edit(root, path, content) or { return err.msg().contains('control characters') }
	return false
}
