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

fn test_repository_map_ranks_case_insensitive_path_and_symbol_mentions() {
	root := os.join_path(os.temp_dir(), 'veasel-repo-map-${os.getpid()}-case')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
	}
	write_map_fixture_file(os.join_path(root, 'src', 'AuthService.java'), 'public class AuthService {\n  void loginUser() {}\n}\n')
	write_map_fixture_file(os.join_path(root, 'src', 'other.go'), 'package main\n\nfunc unusedHelper() {}\n')
	result := build_repository_map(root, 'Please fix LoginUser in SRC/AUTHSERVICE.JAVA',
		repository_map_default_budget_bytes) or { panic(err) }
	assert result.text.contains('src/AuthService.java')
	assert result.text.contains('loginUser') || result.ranked_paths.any(it.contains('AuthService.java'))
	auth_pos := result.text.index('src/AuthService.java') or { -1 }
	other_pos := result.text.index('src/other.go') or { -1 }
	assert auth_pos >= 0
	assert other_pos < 0 || auth_pos < other_pos
	assert repository_map_looks_like_path('pkg/AuthService.java')
	assert repository_map_looks_like_path('scripts/deploy.sh')
	assert repository_map_path_matches_mention('src/AuthService.java', 'SRC/AUTHSERVICE.JAVA')
	assert repository_map_eq_ci('loginUser', 'LoginUser')
}

fn test_repository_map_ranks_directory_prefix_and_segment_mentions() {
	root := os.join_path(os.temp_dir(), 'veasel-repo-map-${os.getpid()}-dir')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
	}
	write_map_fixture_file(os.join_path(root, 'src', 'auth', 'session.v'), 'module auth\n\npub fn open_session() {}\n')
	write_map_fixture_file(os.join_path(root, 'src', 'other', 'noise.v'), 'module other\n\npub fn ignore_me() {}\n')
	write_map_fixture_file(os.join_path(root, 'readme_noise.v'), 'module main\n\nfn unused() {}\n')
	result := build_repository_map(root, 'Look under src/auth for the session flow',
		repository_map_default_budget_bytes) or { panic(err) }
	assert result.ranked_paths.len >= 1
	assert result.ranked_paths[0].contains('src/auth/') || result.ranked_paths[0].ends_with('session.v')
	auth_pos := result.text.index('src/auth/session.v') or { -1 }
	other_pos := result.text.index('src/other/noise.v') or { -1 }
	assert auth_pos >= 0
	assert other_pos < 0 || auth_pos < other_pos
	assert repository_map_path_under_mention('src/auth/session.v', 'src/auth')
	assert repository_map_path_under_mention('src/auth/session.v', 'SRC/AUTH/')
	assert !repository_map_path_under_mention('src/auth', 'src/auth')
	assert repository_map_path_has_segment('src/auth/session.v', 'auth')
	assert !repository_map_path_has_segment('src/other/noise.v', 'auth')
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
	assert messages[0].content.contains('main.v')
	assert messages[0].content.contains('boot_agent')
	assert messages[0].content.contains('untrusted')
}

fn test_sticky_repository_map_system_prefix_ignores_turn_hints() {
	root := os.join_path(os.temp_dir(), 'veasel-repo-map-${os.getpid()}-sticky')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
	}
	write_map_fixture_file(os.join_path(root, 'src', 'alpha.v'), 'module src\n\nfn alpha_symbol() {}\n')
	write_map_fixture_file(os.join_path(root, 'src', 'beta.v'), 'module src\n\nfn beta_symbol() {}\n')
	mut first := [
		ChatMessage{
			role:    'system'
			content: 'You are Veasel Code.'
		},
	]
	mut second := [
		ChatMessage{
			role:    'system'
			content: 'You are Veasel Code.'
		},
	]
	a := maybe_attach_repository_map(mut first, root, 'Please change alpha_symbol in src/alpha.v',
		4_096) or { panic(err) }
	b := maybe_attach_repository_map(mut second, root, 'Now touch beta_symbol in src/beta.v',
		4_096) or { panic(err) }
	assert a.measurement.injected
	assert b.measurement.injected
	assert first[0].content == second[0].content
}

fn test_repository_map_focus_attaches_to_user_for_code_mentions_only() {
	root := os.join_path(os.temp_dir(), 'veasel-repo-map-${os.getpid()}-focus')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
	}
	write_map_fixture_file(os.join_path(root, 'src', 'widget.v'), 'module src\n\nfn render_widget() {}\n')
	write_map_fixture_file(os.join_path(root, 'src', 'other.v'), 'module src\n\nfn unused_helper() {}\n')
	assert repository_map_ident_looks_code_like('render_widget')
	assert repository_map_ident_looks_code_like('AuthService')
	assert !repository_map_ident_looks_code_like('please')
	assert !repository_map_ident_looks_code_like('fix')

	mut casual := [
		ChatMessage{
			role:    'system'
			content: 'system'
		},
		ChatMessage{
			role:    'user'
			content: 'hello there please help'
		},
	]
	skipped := maybe_attach_repository_map_focus(mut casual, root, casual[1].content, 2_048) or {
		panic(err)
	}
	assert !skipped.measurement.injected
	assert !casual[1].content.contains(repository_map_focus_open)

	mut focused := [
		ChatMessage{
			role:    'system'
			content: 'system'
		},
		ChatMessage{
			role:    'user'
			content: 'Please fix render_widget in src/widget.v'
		},
	]
	result := maybe_attach_repository_map_focus(mut focused, root, focused[1].content, 2_048) or {
		panic(err)
	}
	assert result.measurement.injected
	assert focused[1].content.contains(repository_map_focus_open)
	assert focused[1].content.contains('src/widget.v')
	assert focused[1].content.contains('untrusted')
	assert result.measurement.bytes <= repository_map_focus_budget_bytes + repository_map_focus_open.len + repository_map_focus_close.len + 16
}

fn test_clamp_repository_map_budget_bounds() {
	assert clamp_repository_map_budget(0) == repository_map_default_budget_bytes
	assert clamp_repository_map_budget(10) == repository_map_min_budget_bytes
	assert clamp_repository_map_budget(1_000_000) == repository_map_max_budget_bytes
	assert clamp_repository_map_budget(4_096) == 4_096
}
