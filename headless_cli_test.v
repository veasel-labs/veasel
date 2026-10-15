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
		assert err.msg().contains('${max_headless_prompt_bytes}-byte limit')
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

fn test_headless_cli_trace_export_is_explicit_and_validated() {
	options := parse_headless_run_args(['--prompt', 'Task', '--trace-file', 'out/trace.json'],
		'/tmp') or { panic(err) }
	assert options.trace_file == 'out/trace.json'
	if _ := parse_headless_run_args(['--prompt', 'Task', '--trace-file', ''], '/tmp') {
		assert false
	} else {
		assert err.msg().contains('trace-file expects')
	}
	if _ := parse_headless_run_args(['--prompt', 'Task', '--trace-file', 'one', '--trace-file',
		'two'],
		'/tmp') {
		assert false
	} else {
		assert err.msg().contains('trace-file expects')
	}
}

fn test_headless_trace_file_write_publishes_complete_content() {
	path := os.join_path(os.temp_dir(), 'veasel-trace-${os.getpid()}.json')
	defer {
		os.rm(path) or {}
		os.rm('${path}.tmp') or {}
	}
	write_atif_trace_file(path, '{"schema_version":"ATIF-v1.8"}') or { panic(err) }
	assert os.read_file(path) or { panic(err) } == '{"schema_version":"ATIF-v1.8"}'
	$if !windows {
		mode := os.stat(path)!.get_mode()
		assert mode.owner.read && mode.owner.write
		assert !mode.group.read && !mode.group.write && !mode.group.execute
		assert !mode.others.read && !mode.others.write && !mode.others.execute
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

fn test_headless_usage_summary_includes_reported_tokens_only() {
	without_usage := format_headless_usage_summary(HeadlessRunResult{
		session_id: '123e4567-e89b-42d3-a456-426614174000'
		provider:   'openai-compatible'
		model:      'fixture'
	})
	assert without_usage == 'session 123e4567-e89b-42d3-a456-426614174000 · openai-compatible / fixture'
	assert !without_usage.contains(' in · ')
	with_usage := format_headless_usage_summary(HeadlessRunResult{
		session_id:     '123e4567-e89b-42d3-a456-426614174000'
		provider:       'openai-compatible'
		model:          'fixture'
		input_tokens:   1200
		output_tokens:  340
		usage_reported: true
	})
	assert with_usage == 'session 123e4567-e89b-42d3-a456-426614174000 · openai-compatible / fixture · 1200 in · 340 out'
}

fn test_attach_headless_session_usage_skips_empty_session_ids() {
	mut result := HeadlessRunResult{
		status: 'completed'
	}
	attach_headless_session_usage(1, mut result)
	assert !result.session_usage_reported
	assert result.session_completed_turns == 0
}
