module main

import os
import uuid
import encoding.utf8

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
	range := workspace_file_range(root, 'src/main.v', 2, 1) or { panic(err) }
	assert range.path == 'src/main.v'
	assert range.start_line == 2
	assert range.end_line == 2
	assert range.total_lines == 2
	assert range.content == '2: fn main() {}\n'
	assert !range.truncated
	assert workspace_file_range_error_contains(root, 'src/main.v', 0, 1, 'line range')
	assert workspace_file_range_error_contains(root, 'src/main.v', 4, 1, 'line count')
	assert workspace_file_error_contains(root, '../outside-link/secret.txt', 'must not leave')
	assert workspace_file_error_contains(root, 'outside-link/secret.txt', 'escapes')
}

fn test_workspace_file_range_preserves_line_endings_and_bounds_utf8_output() {
	root := os.join_path(os.temp_dir(), 'veasel-workspace-range-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'mixed.txt')
	os.write_file(path, 'α\r\n\nβ\rγ\n') or { panic(err) }
	first := workspace_file_range(root, 'mixed.txt', 1, 2) or { panic(err) }
	assert first.total_lines == 4
	assert first.end_line == 2
	assert first.content == '1: α\n2: \n'
	assert first.truncated
	last := workspace_file_range(root, 'mixed.txt', 3, 2) or { panic(err) }
	assert last.total_lines == 4
	assert last.end_line == 4
	assert last.content == '3: β\n4: γ\n'
	assert !last.truncated

	os.write_file(path, 'λ'.repeat(max_workspace_read_range_bytes / 2 + 20)) or { panic(err) }
	long_line := workspace_file_range(root, 'mixed.txt', 1, 1) or { panic(err) }
	assert long_line.truncated
	assert long_line.content.len <= max_workspace_read_range_bytes
	assert long_line.content.len >= max_workspace_read_range_bytes - 1
	assert utf8.validate(long_line.content.str, long_line.content.len)
	os.write_file(path, 'x'.repeat(max_workspace_read_range_bytes + 20)) or { panic(err) }
	max_line := workspace_file_range(root, 'mixed.txt', 1, 1) or { panic(err) }
	assert max_line.content.len == max_workspace_read_range_bytes
	first_line := 'x'.repeat(max_workspace_read_range_bytes - 7)
	os.write_file(path, '${first_line}\nsecond\n') or { panic(err) }
	near_limit := workspace_file_range(root, 'mixed.txt', 1, 2) or { panic(err) }
	assert near_limit.end_line == 1
	assert near_limit.total_lines == 2
	assert near_limit.truncated
	assert !near_limit.content.contains('second')
}

fn test_workspace_search_is_literal_bounded_and_skips_binary_files() {
	root := os.join_path(os.temp_dir(), 'veasel-workspace-search-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	os.write_file(os.join_path(root, 'one.txt'), 'alpha\nneedle in one\n') or { panic(err) }
	os.write_file(os.join_path(root, 'two.txt'), 'needle in two\n') or { panic(err) }
	os.write_file(os.join_path(root, 'mixed.txt'), 'first\rneedle carriage\r\nneedle windows\nprefix needle unicode🙂\rneedle final') or {
		panic(err)
	}
	os.write_file(os.join_path(root, 'binary.dat'), 'skip\x00needle') or { panic(err) }
	os.write_file(os.join_path(root, 'invalid-utf8.dat'), '\xff') or { panic(err) }
	result := workspace_search(root, 'needle') or { panic(err) }
	assert result.matches.len == 6
	assert result.matches[0] == WorkspaceSearchMatch{
		path: 'mixed.txt'
		line: 2
		text: 'needle carriage'
	}
	assert result.matches[1] == WorkspaceSearchMatch{
		path: 'mixed.txt'
		line: 3
		text: 'needle windows'
	}
	assert result.matches[2] == WorkspaceSearchMatch{
		path: 'mixed.txt'
		line: 4
		text: 'prefix needle unicode🙂'
	}
	assert result.matches[3] == WorkspaceSearchMatch{
		path: 'mixed.txt'
		line: 5
		text: 'needle final'
	}
	assert result.matches[4] == WorkspaceSearchMatch{
		path: 'one.txt'
		line: 2
		text: 'needle in one'
	}
	assert result.matches[5].path == 'two.txt'
	assert result.matches[5].line == 1
	assert !result.truncated
	assert workspace_file_error_contains(root, 'binary.dat', 'binary files')
	assert workspace_file_error_contains(root, 'invalid-utf8.dat', 'UTF-8')
	assert workspace_search_error_contains(root, '   ', 'search query')
	assert workspace_search_error_contains(root, 'x'.repeat(max_workspace_query_bytes + 1),
		'search query')
}

fn test_workspace_excerpt_trims_and_crops_once_at_utf8_boundaries() {
	assert workspace_excerpt('\t  hello\r', 5) == 'hello'
	assert workspace_excerpt('x'.repeat(4_096), 5) == 'xxxxx'
	assert workspace_excerpt('aéx', 2) == 'a'
	assert workspace_excerpt('éx', 2) == 'é'
	assert workspace_excerpt(' \t\r', 4) == ''
	assert workspace_excerpt('hello', 0) == ''
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

fn test_workspace_edit_refuses_while_git_index_lock_is_held() {
	root := os.join_path(os.temp_dir(), 'veasel-git-lock-${uuid.new_v4().str()}')
	os.mkdir_all(os.join_path(root, '.git')) or { panic(err) }
	os.mkdir_all(os.join_path(root, 'src')) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
	}
	os.write_file(os.join_path(root, 'src', 'main.v'), 'module fixture\n') or { panic(err) }
	lock_path := os.join_path(root, '.git', 'index.lock')
	os.write_file(lock_path, '') or { panic(err) }
	_ := prepare_workspace_edit(root, 'src/main.v', 'module fixture\nfn main() {}\n') or {
		assert err.msg().contains('index.lock')
		os.rm(lock_path) or { panic(err) }
		draft := prepare_workspace_edit(root, 'src/main.v', 'module fixture\nfn main() {}\n') or {
			panic(err)
		}
		os.write_file(lock_path, '') or { panic(err) }
		edit := StoredWorkspaceEdit{
			id:            uuid.new_v4().str()
			path:          draft.path
			expected_hash: draft.expected_hash
			content:       draft.content
			diff:          draft.diff
			create_file:   draft.create_file
			status:        'applying'
		}
		apply_workspace_edit(root, edit) or {
			assert err.msg().contains('index.lock')
			return
		}
		assert false, 'apply should refuse while index.lock exists'
		return
	}
	assert false, 'prepare should refuse while index.lock exists'
}

fn test_workspace_git_directory_resolves_linked_worktree_pointer() {
	main_root := os.join_path(os.temp_dir(), 'veasel-git-main-${uuid.new_v4().str()}')
	worktree := os.join_path(os.temp_dir(), 'veasel-git-wt-${uuid.new_v4().str()}')
	gitdir := os.join_path(main_root, '.git', 'worktrees', 'feature')
	os.mkdir_all(gitdir) or { panic(err) }
	os.mkdir_all(worktree) or { panic(err) }
	defer {
		os.rmdir_all(main_root) or {}
		os.rmdir_all(worktree) or {}
	}
	os.write_file(os.join_path(worktree, '.git'), 'gitdir: ${gitdir}\n') or { panic(err) }
	resolved := workspace_git_directory(worktree) or { panic(err) }
	assert resolved == os.real_path(gitdir)
	os.write_file(os.join_path(gitdir, 'HEAD.lock'), '') or { panic(err) }
	_ := prepare_workspace_edit(worktree, 'note.txt', 'hello\n') or {
		assert err.msg().contains('HEAD.lock')
		return
	}
	assert false, 'linked worktree prepare should refuse while HEAD.lock exists'
}

fn workspace_file_error_contains(root string, path string, expected string) bool {
	_ := workspace_file(root, path) or { return err.msg().contains(expected) }
	return false
}

fn workspace_file_range_error_contains(root string, path string, start_line int, line_count int,
	expected string) bool {
	_ := workspace_file_range(root, path, start_line, line_count) or { return err.msg().contains(expected) }
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
