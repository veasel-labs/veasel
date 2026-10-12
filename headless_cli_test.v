module main

import os
import time

fn test_headless_cli_parses_required_prompt_and_workspace_defaults() {
	options := parse_headless_run_args(['--prompt', 'Summarize the repository'], '/tmp/workspace') or {
		panic(err)
	}
	assert options.prompt == 'Summarize the repository'
	assert options.workspace == '/tmp/workspace'
	assert options.session_id == ''
	assert !options.json
	assert int(options.timeout / time.second) == 1800
}

fn test_headless_cli_parses_session_timeout_and_json_options() {
	options := parse_headless_run_args([
		'-p',
		'Continue the current task',
		'--workspace',
		'/tmp/other-workspace',
		'--session',
		'123e4567-e89b-42d3-a456-426614174000',
		'--timeout',
		'45',
		'--json',
	], '/tmp/workspace') or { panic(err) }
	assert options.prompt == 'Continue the current task'
	assert options.workspace == '/tmp/other-workspace'
	assert options.session_id == '123e4567-e89b-42d3-a456-426614174000'
	assert int(options.timeout / time.second) == 45
	assert options.json
}

fn test_headless_cli_rejects_missing_or_oversized_prompts() {
	if _ := parse_headless_run_args([], '/tmp/workspace') {
		assert false
	} else {
		assert err.msg().contains('non-empty --prompt')
	}
	if _ := parse_headless_run_args(['--prompt', '  '], '/tmp/workspace') {
		assert false
	} else {
		assert err.msg().contains('non-empty --prompt')
	}
	too_large := 'x'.repeat(max_headless_prompt_bytes + 1)
	if _ := parse_headless_run_args(['--prompt', too_large], '/tmp/workspace') {
		assert false
	} else {
		assert err.msg().contains('100000-byte limit')
	}
}

fn test_headless_cli_rejects_invalid_session_and_timeout_values() {
	for invalid_id in ['not-a-uuid', '00000000-0000-0000-0000-000000000000'] {
		if _ := parse_headless_run_args(['--prompt', 'Task', '--session', invalid_id], '/tmp') {
			assert false
		} else {
			assert err.msg().contains('session must be')
		}
	}
	for timeout in ['0', '86401', 'invalid'] {
		if _ := parse_headless_run_args(['--prompt', 'Task', '--timeout', timeout], '/tmp') {
			assert false
		} else {
			assert err.msg().contains('timeout expects')
		}
	}
}

fn test_headless_cli_rejects_duplicate_prompt_and_unknown_flags() {
	if _ := parse_headless_run_args(['--prompt', 'one', '--prompt', 'two'], '/tmp') {
		assert false
	} else {
		assert err.msg().contains('one non-empty')
	}
	if _ := parse_headless_run_args(['--prompt', 'Task', '--unsafe'], '/tmp') {
		assert false
	} else {
		assert err.msg().contains('unknown run option')
	}
}

fn test_headless_cli_defaults_to_current_directory_when_requested() {
	options := parse_headless_run_args(['--prompt', 'Task', '--workspace', os.getwd()], '/') or {
		panic(err)
	}
	assert os.real_path(options.workspace) == os.real_path(os.getwd())
}

fn test_headless_result_reconstructs_only_deltas_for_its_operation() {
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{ title: 'Headless result', directory: '/tmp' }) or {
		panic(err)
	}
	first_operation := '123e4567-e89b-42d3-a456-426614174000'
	second_operation := '123e4567-e89b-42d3-a456-426614174001'
	store.record_assistant_delta(session.id, first_operation, 'first ') or { panic(err) }
	store.record_assistant_delta(session.id, second_operation, 'other turn') or { panic(err) }
	store.record_assistant_delta(session.id, first_operation, 'response') or { panic(err) }
	assert store.assistant_text_for_operation(session.id, first_operation) or { panic(err) } == 'first response'
	assert store.assistant_text_for_operation(session.id, second_operation) or { panic(err) } == 'other turn'
}

fn test_event_lookup_index_is_migrated_for_session_result_reads() {
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	indexes := store.db.exec("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'events_session_type_id'") or {
		panic(err)
	}
	assert indexes.len == 1
	assert indexes[0].val(0) == 'events_session_type_id'
}

fn test_headless_session_title_stays_within_byte_limit_without_splitting_unicode() {
	assert headless_session_title('\nExplain this') == 'Veasel Code task'
	assert headless_session_title('  Explain this\nMore detail') == 'Explain this'
	unicode_prompt := 'é'.repeat(99) + '✨' + 'a'
	title := headless_session_title(unicode_prompt)
	assert title.len <= 200
	assert title == 'é'.repeat(99)
}

fn test_headless_failures_keep_session_and_operation_identifiers() {
	result := headless_failed_result('123e4567-e89b-42d3-a456-426614174000',
		'123e4567-e89b-42d3-a456-426614174001', 'state request failed')
	assert result.status == 'failed'
	assert result.session_id == '123e4567-e89b-42d3-a456-426614174000'
	assert result.operation_id == '123e4567-e89b-42d3-a456-426614174001'
	assert result.error == 'state request failed'
}
