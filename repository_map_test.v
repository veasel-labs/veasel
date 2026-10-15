module main

import os

fn write_map_fixture_file(path string, content string) {
	os.mkdir_all(os.dir(path)) or { panic(err) }
	os.write_file(path, content) or { panic(err) }
}

fn test_repository_map_ranks_mentioned_paths_and_symbols() {
	root := os.join_path(os.temp_dir(), 'veasel-repo-map-${os.getpid()}-rank')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
	}
	write_map_fixture_file(os.join_path(root, 'README.md'), '# Demo\n')
	write_map_fixture_file(os.join_path(root, 'src', 'widget.v'), 'module main\n\npub fn render_widget() {}\n\nstruct WidgetState {}\n')
	write_map_fixture_file(os.join_path(root, 'src', 'other.v'), 'module main\n\nfn unused_helper() {}\n')
	write_map_fixture_file(os.join_path(root, 'notes.txt'), 'plain notes without symbols\n')
	result := build_repository_map(root, 'Please fix render_widget in src/widget.v',
		repository_map_default_budget_bytes) or { panic(err) }
	assert result.text.contains(repository_map_open)
	assert result.text.contains('untrusted')
	assert result.text.contains('src/widget.v')
	assert result.text.contains('render_widget')
	assert result.measurement.bytes == result.text.len
	assert result.measurement.estimated_token_bound == estimate_token_bound_from_bytes(result.text.len)
	assert result.measurement.bytes <= repository_map_default_budget_bytes
	assert result.ranked_paths.len > 0
	widget_pos := result.text.index('src/widget.v') or { -1 }
	other_pos := result.text.index('src/other.v') or { -1 }
	assert widget_pos >= 0
	assert other_pos < 0 || widget_pos < other_pos
}

fn test_repository_map_respects_byte_budget_on_large_trees() {
	root := os.join_path(os.temp_dir(), 'veasel-repo-map-${os.getpid()}-large')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
	}
	for index in 0 .. 80 {
		name := 'file_${index:02}.v'
		write_map_fixture_file(os.join_path(root, 'pkg', name), 'module pkg\n\nfn symbol_number_${index}() {}\nfn another_symbol_${index}() {}\n')
	}
	budget := 2_048
	result := build_repository_map(root, 'symbol_number_3', budget) or { panic(err) }
	assert result.measurement.bytes == result.text.len
	assert result.measurement.bytes <= budget
	assert result.measurement.budget_bytes == budget
	assert result.measurement.truncated
	assert result.text.contains(repository_map_close)
}

fn test_repository_map_handles_empty_and_malformed_workspace() {
	empty_root := os.join_path(os.temp_dir(), 'veasel-repo-map-${os.getpid()}-empty')
	os.rmdir_all(empty_root) or {}
	os.mkdir_all(empty_root) or { panic(err) }
	defer {
		os.rmdir_all(empty_root) or {}
	}
	empty := build_repository_map(empty_root, '', 4_096) or { panic(err) }
	assert empty.text.contains('(no workspace files indexed)')
	assert empty.measurement.file_count == 0
	assert empty.measurement.bytes == empty.text.len

	mut missing_failed := false
	build_repository_map(os.join_path(empty_root, 'does-not-exist'), '', 4_096) or {
		missing_failed = err.msg().len > 0
	}
	assert missing_failed

	bad_root := os.join_path(os.temp_dir(), 'veasel-repo-map-${os.getpid()}-bad')
	os.rmdir_all(bad_root) or {}
	os.mkdir_all(bad_root) or { panic(err) }
	defer {
		os.rmdir_all(bad_root) or {}
	}
	write_map_fixture_file(os.join_path(bad_root, 'ok.v'), 'fn ok_symbol() {}\n')
	write_map_fixture_file(os.join_path(bad_root, 'binary.bin'), 'a\x00b\x00c')
	write_map_fixture_file(os.join_path(bad_root, 'weird name.v'), 'fn collision_one() {}\n')
	write_map_fixture_file(os.join_path(bad_root, 'subdir', 'weird name.v'), 'fn collision_two() {}\n')
	result := build_repository_map(bad_root, 'collision_two', 8_192) or { panic(err) }
	assert result.text.contains('ok.v')
	assert !result.text.contains('\x00')
	assert result.text.contains('collision_two') || result.ranked_paths.any(it.contains('weird name.v'))
}

fn test_maybe_attach_repository_map_marks_injection() {
	root := os.join_path(os.temp_dir(), 'veasel-repo-map-${os.getpid()}-inject')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
	}
	write_map_fixture_file(os.join_path(root, 'main.v'), 'module main\n\nfn boot_agent() {}\n')
	mut messages := [
		ChatMessage{
			role:    'system'
			content: 'You are Veasel Code.'
		},
	]
	result := maybe_attach_repository_map(mut messages, root, 'boot_agent', 4_096) or {
		panic(err)
	}
	assert result.measurement.injected
	assert messages[0].content.contains(repository_map_open)
	assert messages[0].content.contains('boot_agent')
	assert messages[0].content.contains('untrusted')
}

fn test_clamp_repository_map_budget_bounds() {
	assert clamp_repository_map_budget(0) == repository_map_default_budget_bytes
	assert clamp_repository_map_budget(10) == repository_map_min_budget_bytes
	assert clamp_repository_map_budget(1_000_000) == repository_map_max_budget_bytes
	assert clamp_repository_map_budget(4_096) == 4_096
}
