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

fn test_repository_map_prefers_production_for_behavior_queries_and_respects_test_queries() {
	root := os.join_path(os.temp_dir(), 'veasel-repo-map-${os.getpid()}-lexical')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
	}
	write_map_fixture_file(os.join_path(root, 'src', 'agents', 'default.py'),
		'class DefaultAgent:\n    def run(self):\n        pass\n')
	write_map_fixture_file(os.join_path(root, 'tests', 'agents', 'test_init.py'),
		'class TestAgent:\n    def test_agent(self):\n        pass\n')
	write_map_fixture_file(os.join_path(root, 'aider', 'args.py'),
		'def get_parser():\n    """Parse command line arguments and options."""\n')
	behavior := build_repository_map(root, 'the main agent loop that runs until done',
		repository_map_default_budget_bytes) or { panic(err) }
	assert behavior.ranked_paths[0].ends_with('src/agents/default.py')
	test_query := build_repository_map(root, 'test the agent loading behavior',
		repository_map_default_budget_bytes) or { panic(err) }
	assert test_query.ranked_paths.any(it.ends_with('tests/agents/test_init.py'))
	arguments := extract_repository_map_hints('command line argument parsing and options')
	assert repository_map_lexically_related('args', 'arguments')
	assert repository_map_path_has_segment('aider/args.py', 'args')
	assert score_repository_map_path('aider/args.py', arguments) >= 300.0
	assert score_repository_map_content('Add an argument to the command line parser options.',
		arguments) > 0.0
	assert score_repository_map_content('parse_args parser', RepositoryMapHintSet{
		idents: ['parsing']
	}) == 24.0
	assert score_repository_map_content('run_batch', RepositoryMapHintSet{
		idents: ['running']
	}) == 24.0
	assert score_repository_map_path('aider/args.py', arguments) > score_repository_map_path('tests/test_args.py', arguments)
	model_behavior := extract_repository_map_hints('litellm model that calls the LLM API')
	assert repository_map_is_package_index_path('src/minisweagent/models/__init__.py')
	assert !repository_map_is_package_index_path('src/minisweagent/models/litellm_model.py')
	assert !repository_map_hint_mentions_package_indexes(model_behavior)
	assert repository_map_content_is_reexport_only('from .litellm_model import LiteLLMModel\n__all__ = ["LiteLLMModel"]')
	assert repository_map_content_is_reexport_only("export { createClient } from './client.js'\n")
	assert !repository_map_content_is_reexport_only('export function createClient() {}')
	export_query := extract_repository_map_hints('show the package exports and entrypoint')
	assert repository_map_hint_mentions_package_indexes(export_query)
	history_query := extract_repository_map_hints('format the chat history for the model')
	assert score_repository_map_path('aider/history.py', history_query) > score_repository_map_path('aider/models.py', history_query)
	args_query := extract_repository_map_hints('command line argument parsing and options')
	assert score_repository_map_path('aider/args.py', args_query) > score_repository_map_path('aider/io.py', args_query)
	subagent_query := extract_repository_map_hints('resume the subagent job and notify the parent session')
	assert score_repository_map_path('packages/core/src/session/subagent-job.ts', subagent_query) > score_repository_map_path('packages/core/src/session/operation.ts', subagent_query)
	spawn_subagent_query := extract_repository_map_hints('spawn a subagent tool for a task')
	assert score_repository_map_path('packages/core/src/tool/plugin/subagent.ts', spawn_subagent_query) > score_repository_map_path('packages/core/src/tool.ts', spawn_subagent_query)
	paired := extract_repository_map_hints('Please fix src/agents/default.py')
	assert score_repository_map_path('tests/agents/test_init.py', paired) < score_repository_map_path('src/agents/default.py', paired)
	assert repository_map_lexically_related('policy', 'policies')
	assert repository_map_lexically_related('class', 'classes')
	assert score_repository_map_content('class policy', RepositoryMapHintSet{
		idents: [
			'classes',
			'policy',
		]
	}) == 48.0
	assert score_repository_map_content('classes policies', RepositoryMapHintSet{
		idents: [
			'class',
			'policy',
		]
	}) == 48.0
	assert score_repository_map_path('src/AuthService.ts', RepositoryMapHintSet{ idents: ['auth'] }) > score_repository_map_path('src/Other.ts', RepositoryMapHintSet{ idents: ['auth'] })
	assert repository_map_is_test_path('src/auth.spec.ts')
	assert repository_map_is_test_path('src/__specs__/auth_spec.ts')
	assert !repository_map_is_test_path('src/AuthService.ts')
	case_hints := RepositoryMapHintSet{ idents: ['AGENT', 'agent', 'Agent', 'args'] }
	assert !repository_map_is_lexical_hint('The')
	assert !repository_map_is_lexical_hint('For')
	assert score_repository_map_content('agent argument parser', case_hints) == 72.0
	assert score_repository_map_path('src/agent.py', case_hints) == score_repository_map_path('src/agent.py', RepositoryMapHintSet{
		idents: [
			'agent',
			'args',
		]
	})
}

fn test_repository_map_extracts_go_methods_and_modified_class_declarations() {
	content := 'package store\n\nfunc (s *Store) LoadSession(id string) {}\nfunc (r *Box[func(int)]) Transform() {}\npublic class SessionController {}\nexport default function createSession() {}\npub fn open_session() {}\ndata class SessionState(val id: String)\nsuspend fun loadSession() {}\npublic protocol SessionStore {}\nextension SessionState {}\n'
	symbols := extract_repository_map_symbols(content)
	mut names := []string{}
	mut kinds := []string{}
	for symbol in symbols {
		names << symbol.name
		kinds << symbol.kind
	}
	assert names == ['LoadSession', 'Transform', 'SessionController', 'createSession', 'open_session',
		'SessionState', 'loadSession', 'SessionStore', 'SessionState']
	assert kinds == ['func', 'func', 'public class', 'export default function', 'pub fn', 'data class',
		'suspend fun', 'public protocol', 'extension']
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

fn test_repository_map_ranks_test_pairs_and_symbol_parts() {
	root := os.join_path(os.temp_dir(), 'veasel-repo-map-${os.getpid()}-pairs')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
	}
	write_map_fixture_file(os.join_path(root, 'src', 'session.v'), 'module session\n\npub fn open_session() {}\n')
	write_map_fixture_file(os.join_path(root, 'src', 'session_test.v'), 'module session\n\nfn test_open_session() {}\n')
	write_map_fixture_file(os.join_path(root, 'src', 'unrelated.v'), 'module unrelated\n\nfn noise() {}\n')
	write_map_fixture_file(os.join_path(root, 'pkg', 'auth_service.v'), 'module auth\n\npub fn login_user() {}\n')
	paired := build_repository_map(root, 'Inspect session.v behavior', repository_map_default_budget_bytes) or {
		panic(err)
	}
	assert paired.ranked_paths.any(it.ends_with('session_test.v'))
	parts := build_repository_map(root, 'Where is loginUser defined?', repository_map_default_budget_bytes) or {
		panic(err)
	}
	assert parts.text.contains('login_user') || parts.ranked_paths.any(it.contains('auth_service'))
	assert repository_map_is_test_pair('src/session_test.v', 'session.v')
	assert repository_map_stems_are_test_pair('session_test', 'session')
	assert repository_map_symbol_part_match('login_user', 'loginUser')
	assert !repository_map_symbol_part_match('login_user', 'login_user')
}

fn test_repository_map_boosts_directory_neighbors_of_mentions() {
	root := os.join_path(os.temp_dir(), 'veasel-repo-map-${os.getpid()}-neighbors')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
	}
	write_map_fixture_file(os.join_path(root, 'src', 'auth', 'session.v'), 'module auth\n\npub fn open_session() {}\n')
	write_map_fixture_file(os.join_path(root, 'src', 'auth', 'tokens.v'), 'module auth\n\npub fn mint_token() {}\n')
	write_map_fixture_file(os.join_path(root, 'src', 'other', 'noise.v'), 'module other\n\npub fn ignore_me() {}\n')
	result := build_repository_map(root, 'Please read src/auth/session.v', 2_048) or { panic(err) }
	assert result.ranked_paths.any(it.ends_with('tokens.v'))
	assert result.text.contains('src/auth/tokens.v')
}

fn test_repository_map_boosts_cross_directory_same_stem_siblings() {
	root := os.join_path(os.temp_dir(), 'veasel-repo-map-${os.getpid()}-stems')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
	}
	write_map_fixture_file(os.join_path(root, 'lib', 'session.v'), 'module libsession\n\npub fn open_session() {}\n')
	write_map_fixture_file(os.join_path(root, 'cmd', 'tools', 'session.v'), 'module cmdsession\n\npub fn run_session_tool() {}\n')
	write_map_fixture_file(os.join_path(root, 'pkg', 'noise.v'), 'module noise\n\npub fn ignore_me() {}\n')
	result := build_repository_map(root, 'Please read lib/session.v', 2_048) or { panic(err) }
	assert result.ranked_paths.any(it.contains('cmd/tools/session.v') || it.ends_with('tools/session.v'))
	assert result.text.contains('cmd/tools/session.v')
}

fn test_repository_map_boosts_stem_package_file_and_directory() {
	root := os.join_path(os.temp_dir(), 'veasel-repo-map-${os.getpid()}-packages')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
	}
	write_map_fixture_file(os.join_path(root, 'lib', 'session.v'), 'module libsession\n\npub fn open_session() {}\n')
	write_map_fixture_file(os.join_path(root, 'lib', 'session', 'handler.v'), 'module sessionhandler\n\npub fn handle_session() {}\n')
	write_map_fixture_file(os.join_path(root, 'pkg', 'noise.v'), 'module noise\n\npub fn ignore_me() {}\n')
	forward := build_repository_map(root, 'Please read lib/session.v', 2_048) or { panic(err) }
	assert forward.ranked_paths.any(it.contains('lib/session/handler.v') || it.ends_with('session/handler.v'))
	assert forward.text.contains('lib/session/handler.v')
	reverse := build_repository_map(root, 'Please read lib/session/handler.v', 2_048) or {
		panic(err)
	}
	assert reverse.ranked_paths.any(it.ends_with('lib/session.v') || it == 'lib/session.v')
	assert reverse.text.contains('lib/session.v')
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

fn test_repository_map_cross_references_rank_central_files() {
	root := os.join_path(os.temp_dir(), 'veasel-repo-map-${os.getpid()}-xref')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
	}
	write_map_fixture_file(os.join_path(root, 'src', 'central.v'), 'module main\n\npub fn shared_helper() {}\n')
	write_map_fixture_file(os.join_path(root, 'src', 'user_one.v'), 'module main\n\nfn run_one() { shared_helper() }\n')
	write_map_fixture_file(os.join_path(root, 'src', 'user_two.v'), 'module main\n\nfn run_two() { shared_helper() }\n')
	write_map_fixture_file(os.join_path(root, 'src', 'user_three.v'), 'module main\n\nfn run_three() { shared_helper() }\n')
	mut noisy := 'module main\n\n'
	for index in 0 .. 10 {
		noisy += 'fn noisy_${index}() {}\n'
	}
	write_map_fixture_file(os.join_path(root, 'src', 'noisy.v'), noisy)
	result := build_repository_map(root, 'Improve the workspace', repository_map_default_budget_bytes) or {
		panic(err)
	}
	assert result.ranked_paths.len > 0
	assert result.ranked_paths[0] == 'src/central.v'
}

fn test_repository_map_cross_references_personalize_hint_referrers() {
	root := os.join_path(os.temp_dir(), 'veasel-repo-map-${os.getpid()}-xref-hint')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
	}
	// Both targets are referenced exactly once. Only alpha_target is
	// referenced from the hint-mentioned directory, so personalization must
	// rank it above beta_target.
	write_map_fixture_file(os.join_path(root, 'src', 'alpha_target.v'), 'module main\n\npub fn alpha_helper() {}\n')
	write_map_fixture_file(os.join_path(root, 'src', 'beta_target.v'), 'module main\n\npub fn beta_helper() {}\n')
	write_map_fixture_file(os.join_path(root, 'auth', 'handler.v'), 'module main\n\nfn handle() { alpha_helper() }\n')
	write_map_fixture_file(os.join_path(root, 'misc', 'other.v'), 'module main\n\nfn other() { beta_helper() }\n')
	result := build_repository_map(root, 'Fix the auth handler', repository_map_default_budget_bytes) or {
		panic(err)
	}
	alpha_index := result.ranked_paths.index('src/alpha_target.v')
	beta_index := result.ranked_paths.index('src/beta_target.v')
	assert alpha_index >= 0
	assert beta_index >= 0
	assert alpha_index < beta_index
}

fn test_repository_map_symbol_count_does_not_flood_ranking() {
	root := os.join_path(os.temp_dir(), 'veasel-repo-map-${os.getpid()}-flood')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
	}
	mut big := 'module noise\n'
	for i in 0 .. 40 {
		big += '\npub fn zebra_process_${i}() {}\n'
	}
	write_map_fixture_file(os.join_path(root, 'src', 'big_noise.v'), big)
	write_map_fixture_file(os.join_path(root, 'src', 'target.v'), 'module target\n\npub fn render_widget() {}\n')
	result := build_repository_map(root, 'Please fix render_widget', repository_map_default_budget_bytes) or {
		panic(err)
	}
	assert result.ranked_paths.len >= 2
	assert result.ranked_paths[0] == 'src/target.v', 'mentioned definer must outrank a large unrelated file: ${result.ranked_paths}'
}

fn test_repository_map_symbol_cache_reuses_only_exact_file_content() {
	mut cache := new_repository_map_symbol_cache()
	path := '/workspace/src/agent.v'
	first_content := 'pub fn first_agent_symbol() {}'
	first := repository_map_cached_symbols(mut cache, path, first_content)
	assert first.len == 1
	assert first[0].name == 'first_agent_symbol'
	assert repository_map_symbol_cache_hits(mut cache) == 0

	reused := repository_map_cached_symbols(mut cache, path, first_content)
	assert reused.len == 1
	assert reused[0].name == 'first_agent_symbol'
	assert repository_map_symbol_cache_hits(mut cache) == 1

	updated := repository_map_cached_symbols(mut cache, path, 'pub fn updated_agent_symbol() {}')
	assert updated.len == 1
	assert updated[0].name == 'updated_agent_symbol'
	assert repository_map_symbol_cache_hits(mut cache) == 1
}

fn test_repository_map_symbol_cache_keeps_earlier_ranked_files_when_full() {
	mut cache := new_repository_map_symbol_cache()
	first_path := 'src/first-ranked.v'
	first_content := 'x'.repeat(repository_map_symbol_cache_max_bytes)
	_ = repository_map_cached_symbols(mut cache, first_path, first_content)
	_ = repository_map_cached_symbols(mut cache, 'src/lower-ranked.v', 'pub fn later_symbol() {}')
	assert cache.entries.len == 1
	assert cache.retained_bytes == repository_map_symbol_cache_max_bytes
	_ = repository_map_cached_symbols(mut cache, first_path, first_content)
	_ = repository_map_cached_symbols(mut cache, 'src/lower-ranked.v', 'pub fn later_symbol() {}')
	assert repository_map_symbol_cache_hits(mut cache) == 1
	assert cache.entries.len == 1
}
