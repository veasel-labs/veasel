module main

import os
import uuid

fn fixture_pressure_messages(older_count int, older_payload string, recent_user string) []ChatMessage {
	mut messages := [
		ChatMessage{
			role:    'system'
			content: 'You are Veasel Code.'
		},
	]
	for index in 0 .. older_count {
		messages << ChatMessage{
			role:    'user'
			content: 'older-user-${index}: ${older_payload}'
		}
		messages << ChatMessage{
			role:    'assistant'
			content: 'older-assistant-${index}: ${older_payload}'
		}
	}
	messages << ChatMessage{
		role:    'user'
		content: recent_user
	}
	return messages
}

fn test_estimate_token_bound_from_bytes_is_ceil_div_four() {
	assert estimate_token_bound_from_bytes(0) == 0
	assert estimate_token_bound_from_bytes(1) == 1
	assert estimate_token_bound_from_bytes(4) == 1
	assert estimate_token_bound_from_bytes(5) == 2
}

fn test_session_compaction_skips_when_under_pressure() {
	messages := [
		ChatMessage{
			role:    'system'
			content: 'You are Veasel Code.'
		},
		ChatMessage{
			role:    'user'
			content: 'Short question.'
		},
	]
	result := compact_session_messages(messages)
	assert !result.measurement.triggered
	assert result.messages.len == messages.len
	assert result.measurement.bytes_before == agent_context_bytes(messages)
	assert result.measurement.bytes_after == result.measurement.bytes_before
	assert result.measurement.estimated_token_bound_before == estimate_token_bound_from_bytes(result.measurement.bytes_before)
}

fn test_session_compaction_reduces_bytes_under_byte_pressure() {
	payload := 'x'.repeat(24_000)
	messages := fixture_pressure_messages(20, payload, 'Continue the latest task with the open files.')
	before := agent_context_bytes(messages)
	assert before >= compaction_pressure_bytes()
	result := compact_session_messages(messages)
	assert result.measurement.triggered
	assert result.measurement.reason == 'byte_pressure'
	assert result.measurement.bytes_before == before
	assert result.measurement.bytes_after < before
	assert result.measurement.summarized_message_count > 0
	assert result.messages.len < messages.len
	assert result.messages[0].role == 'system'
	assert result.messages[0].content == 'You are Veasel Code.'
	assert result.messages[1].role == 'user'
	assert result.messages[1].content.contains(compaction_summary_open)
	assert result.messages[1].content.contains('untrusted')
	assert result.messages[1].content.contains('bytes_before: ${before}')
	assert result.messages[1].content.contains('estimated_token_bound_before: ${estimate_token_bound_from_bytes(before)}')
	assert result.messages[result.messages.len - 1].content == 'Continue the latest task with the open files.'
	assert result.measurement.estimated_token_bound_after == estimate_token_bound_from_bytes(result.measurement.bytes_after)
	assert result.measurement.estimated_token_bound_after < result.measurement.estimated_token_bound_before
}

fn test_session_compaction_preserves_tool_pair_in_recent_tail() {
	payload := 'y'.repeat(24_000)
	mut messages := fixture_pressure_messages(20, payload, 'Inspect the file.')
	messages << ChatMessage{
		role:       'assistant'
		content:    ''
		tool_calls: [
			ProviderToolCall{
				id:       'call-1'
				type:     'function'
				function: ProviderFunctionCall{
					name:      'workspace_read_file'
					arguments: '{"path":"main.v"}'
				}
			},
		]
	}
	messages << ChatMessage{
		role:         'tool'
		name:         'workspace_read_file'
		tool_call_id: 'call-1'
		content:      'fn main() {}\n' + payload
	}
	result := compact_session_messages(messages)
	assert result.measurement.triggered
	mut saw_tool_call := false
	mut saw_tool_result := false
	for message in result.messages {
		if message.role == 'assistant' && message.tool_calls.len == 1 && message.tool_calls[0].id == 'call-1' {
			saw_tool_call = true
		}
		if message.role == 'tool' && message.tool_call_id == 'call-1' {
			saw_tool_result = true
		}
	}
	assert saw_tool_call
	assert saw_tool_result
}

fn test_session_compaction_message_pressure_without_huge_payload() {
	mut messages := [
		ChatMessage{
			role:    'system'
			content: 'You are Veasel Code.'
		},
	]
	// max_chat_messages is 64; conversation pressure triggers at 60 non-system messages.
	for index in 0 .. 61 {
		role := if index % 2 == 0 { 'user' } else { 'assistant' }
		messages << ChatMessage{
			role:    role
			content: 'turn-${index}: small'
		}
	}
	due, reason := session_compaction_due(messages)
	assert due
	assert reason == 'message_pressure'
	result := compact_session_messages(messages)
	assert result.measurement.triggered
	assert result.measurement.reason == 'message_pressure'
	assert result.messages.len < messages.len
	assert result.measurement.summarized_message_count > 0
	assert result.messages[1].content.contains('message_pressure')
	// Prefer a smaller UTF-8 payload, but message-count relief is the contract
	// when turns are tiny; do not require bytes_after < bytes_before here.
}

fn test_compaction_sanitize_strips_nul_bytes() {
	assert sanitize_compaction_text('safe\0unsafe') == 'safeunsafe'
	assert truncate_compaction_excerpt('a\0b\0c', 10) == 'abc'
	assert truncate_compaction_excerpt('\0\0', 10) == ''
}

fn test_compaction_summary_preview_truncates() {
	long_summary := 'a'.repeat(compaction_summary_preview_chars + 40)
	preview := compaction_summary_preview(long_summary)
	assert preview.len > compaction_summary_preview_chars
	assert preview.ends_with('\n[truncated]')
	assert preview.starts_with('a'.repeat(compaction_summary_preview_chars))
}

fn test_session_compaction_event_preserves_durable_chat_history() {
	mut store := open_store(':memory:') or { panic(err) }
	defer {
		store.close() or {}
	}
	session := store.create_session(SessionInput{
		title:     'Compaction'
		directory: os.temp_dir()
	}) or {
		panic(err)
	}
	operation_id := uuid.new_v4().str()
	_ = store.create_session_operation(session.id, operation_id) or { panic(err) }
	_ = store.append_exchange(session.id, operation_id, 'first user', 'first assistant', 'openai',
		'fixture', '', ProviderUsage{}) or { panic(err) }
	before_history := store.messages_for_session(session.id, 10) or { panic(err) }
	assert before_history.len == 2

	payload := 'z'.repeat(24_000)
	messages := fixture_pressure_messages(20, payload, 'Keep going.')
	result := compact_session_messages(messages)
	assert result.measurement.triggered
	store.record_session_compaction(session.id, operation_id, result.measurement, result.summary) or {
		panic(err)
	}

	after_history := store.messages_for_session(session.id, 10) or { panic(err) }
	assert after_history.len == before_history.len
	assert after_history[0].content == 'first user'
	assert after_history[1].content == 'first assistant'
	events := store.events_after(0) or { panic(err) }
	compaction_events := events.filter(it.type == 'session.compaction')
	assert compaction_events.len == 1
	event := compaction_events[0]
	assert event.data.operation_id == operation_id
	assert event.data.compaction_untrusted == true
	assert event.data.compaction_bytes_before == result.measurement.bytes_before
	assert event.data.compaction_bytes_after == result.measurement.bytes_after
	assert event.data.compaction_bytes_after < event.data.compaction_bytes_before
	assert event.data.compaction_token_bound_before == result.measurement.estimated_token_bound_before
	assert event.data.compaction_token_bound_after == result.measurement.estimated_token_bound_after
	assert event.data.compaction_reason == 'byte_pressure'
	assert event.data.compaction_summary_preview.contains('untrusted')
	assert event.data.compaction_summarizer_mode == 'extractive'
	assert event.data.compaction_usage_reported == false
}

fn fixture_llm_success_summarizer(older []ChatMessage, bytes_before int, reason string) !SessionCompactionSummarizerOutput {
	usage := ProviderUsage{
		input_tokens:  11
		output_tokens: 7
		total_tokens:  18
		reported:      true
	}
	body := wrap_llm_compaction_summary('Fixture LLM summary of ${older.len} older turns for ${reason}.',
		bytes_before, reason, usage, older.len)
	return SessionCompactionSummarizerOutput{
		body:  body
		mode:  'llm'
		usage: usage
	}
}

fn fixture_llm_failure_summarizer(_older []ChatMessage, _bytes_before int, _reason string) !SessionCompactionSummarizerOutput {
	return error('fixture summarizer unavailable')
}

fn fixture_llm_growing_summarizer(older []ChatMessage, bytes_before int, reason string) !SessionCompactionSummarizerOutput {
	// Bypass wrap_llm_compaction_summary truncation so the candidate truly grows.
	repeat_count := (bytes_before / 4) + 16_000
	bloated := 'GROW'.repeat(repeat_count)
	mut lines := compaction_summary_header_lines(bytes_before, reason, 'llm', older.len, ProviderUsage{})
	lines << ''
	lines << '### LLM summary (untrusted)'
	lines << bloated
	lines << compaction_summary_close
	return SessionCompactionSummarizerOutput{
		body: lines.join('\n')
		mode: 'llm'
	}
}

fn test_session_compaction_llm_summarizer_success_records_provider_usage() {
	payload := 'x'.repeat(24_000)
	messages := fixture_pressure_messages(20, payload, 'Continue after summarizer.')
	before := agent_context_bytes(messages)
	result := compact_session_messages_with_summarizer(messages, 'llm', fixture_llm_success_summarizer)
	assert result.measurement.triggered
	assert result.measurement.summarizer_mode == 'llm'
	assert result.measurement.bytes_after < before
	assert result.measurement.usage_reported
	assert result.measurement.input_tokens == 11
	assert result.measurement.output_tokens == 7
	assert result.messages[1].content.contains('summarizer_mode: `llm`')
	assert result.messages[1].content.contains('provider_usage_reported: true')
	assert result.messages[1].content.contains('provider_input_tokens: 11')
	assert result.messages[1].content.contains('Fixture LLM summary')
	assert result.messages[1].content.contains(compaction_summary_open)
}

fn test_session_compaction_llm_summarizer_failure_falls_back_extractive() {
	payload := 'x'.repeat(24_000)
	messages := fixture_pressure_messages(20, payload, 'Fallback please.')
	before := agent_context_bytes(messages)
	result := compact_session_messages_with_summarizer(messages, 'llm', fixture_llm_failure_summarizer)
	assert result.measurement.triggered
	assert result.measurement.summarizer_mode == 'llm_fallback_extractive'
	assert result.measurement.bytes_after < before
	assert !result.measurement.usage_reported
	assert result.messages[1].content.contains('Older turns (extractive)')
	assert result.messages[1].content.contains('summarizer_mode: `llm_fallback_extractive`')
}

fn test_session_compaction_llm_summarizer_refuses_when_context_grows() {
	payload := 'x'.repeat(24_000)
	messages := fixture_pressure_messages(20, payload, 'Refuse growth.')
	before := agent_context_bytes(messages)
	result := compact_session_messages_with_summarizer(messages, 'llm', fixture_llm_growing_summarizer)
	assert result.measurement.triggered
	assert result.measurement.summarizer_mode == 'llm_fallback_extractive'
	assert result.measurement.bytes_after < before
	assert result.messages[1].content.contains('Older turns (extractive)')
	assert !result.messages[1].content.contains('GROWGROW')
}

fn test_session_compaction_native_summarizer_and_tool_pair_boundary() {
	payload := 'y'.repeat(24_000)
	mut messages := [
		ChatMessage{
			role:    'system'
			content: 'You are Veasel Code.'
		},
	]
	for index in 0 .. 18 {
		messages << ChatMessage{
			role:    'user'
			content: 'older-user-${index}: review docs/openapi.yaml ${payload}'
		}
		messages << ChatMessage{
			role:       'assistant'
			content:    'older-assistant-${index}'
			tool_calls: [
				ProviderToolCall{
					id:       'older-call-${index}'
					type:     'function'
					function: ProviderFunctionCall{
						name:      'workspace_search'
						arguments: '{"query":"openapi"}'
					}
				},
			]
		}
		messages << ChatMessage{
			role:         'tool'
			name:         'workspace_search'
			tool_call_id: 'older-call-${index}'
			content:      'hit ${payload}'
		}
	}
	messages << ChatMessage{
		role:    'user'
		content: 'Inspect src/main.v carefully.'
	}
	messages << ChatMessage{
		role:       'assistant'
		content:    ''
		tool_calls: [
			ProviderToolCall{
				id:       'call-native-1'
				type:     'function'
				function: ProviderFunctionCall{
					name:      'workspace_read_file'
					arguments: '{"path":"src/main.v"}'
				}
			},
		]
	}
	messages << ChatMessage{
		role:         'tool'
		name:         'workspace_read_file'
		tool_call_id: 'call-native-1'
		content:      'fn main() {}\n' + payload
	}
	assert agent_context_bytes(messages) >= compaction_pressure_bytes()
	result := compact_session_messages_with_summarizer(messages, 'native', native_session_compaction_summarizer)
	assert result.measurement.triggered
	assert result.measurement.summarizer_mode == 'native'
	assert result.measurement.bytes_after < result.measurement.bytes_before
	assert result.messages[1].content.contains('summarizer_mode: `native`')
	assert result.messages[1].content.contains('### Recent user goals')
	assert result.messages[1].content.contains('workspace_search')
	assert result.messages[1].content.contains('docs/openapi.yaml')
	mut saw_tool_call := false
	mut saw_tool_result := false
	for message in result.messages {
		if message.role == 'assistant' && message.tool_calls.len == 1
			&& message.tool_calls[0].id == 'call-native-1' {
			saw_tool_call = true
		}
		if message.role == 'tool' && message.tool_call_id == 'call-native-1' {
			saw_tool_result = true
		}
	}
	assert saw_tool_call
	assert saw_tool_result
}

fn test_session_compaction_summarizer_mode_env_parsing() {
	os.setenv(compaction_summarizer_env, 'native', true)
	assert session_compaction_summarizer_mode() == 'native'
	assert session_compaction_summarizer_enabled()
	os.setenv(compaction_summarizer_env, 'LLM', true)
	assert session_compaction_summarizer_mode() == 'llm'
	os.setenv(compaction_summarizer_env, 'extractive', true)
	assert session_compaction_summarizer_mode() == 'extractive'
	assert !session_compaction_summarizer_enabled()
	os.setenv(compaction_summarizer_env, 'nope', true)
	assert session_compaction_summarizer_mode() == 'extractive'
	os.unsetenv(compaction_summarizer_env)
}

fn test_chat_input_byte_limit_env_override() {
	os.setenv(chat_input_bytes_env, '4194304', true)
	assert chat_input_byte_limit() == 4_194_304
	assert compaction_pressure_bytes() == 4_194_304 * compaction_pressure_ratio_numerator / compaction_pressure_ratio_denominator
	os.setenv(chat_input_bytes_env, '1024', true)
	assert chat_input_byte_limit() == max_chat_input_bytes
	os.setenv(chat_input_bytes_env, '999999999', true)
	assert chat_input_byte_limit() == max_chat_input_bytes
	os.setenv(chat_input_bytes_env, 'not-a-number', true)
	assert chat_input_byte_limit() == max_chat_input_bytes
	os.unsetenv(chat_input_bytes_env)
	assert chat_input_byte_limit() == max_chat_input_bytes
}
