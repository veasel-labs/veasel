module main

import json2
import os

fn test_trace_redaction_removes_env_secret_from_message_arguments_and_observation() {
	os.setenv('VEASEL_TEST_API_KEY', 'env-secret-value-123', true)
	defer { os.unsetenv('VEASEL_TEST_API_KEY') }
	call := atif_tool_call(ProviderToolCall{
		id:       'call-1'
		function: ProviderFunctionCall{
			name:      'workspace_run'
			arguments: '{"command":"deploy --key env-secret-value-123","note":"plain"}'
		}
	}) or { panic(err) }
	encoded := encode_atif_trace('session-1', '0.1.0', 'fixture-model', [
		ATIFStep{
			step_id: 1
			source:  'user'
			message: 'Use env-secret-value-123 for this'
		},
		ATIFStep{
			step_id:     2
			source:      'agent'
			model_name:  'fixture-model'
			message:     ''
			tool_calls:  [call]
			observation: ATIFObservation{
				results: [ATIFObservationResult{
					source_call_id: 'call-1'
					content:        'leaked env-secret-value-123 in output'
				}]
			}
		},
	]) or { panic(err) }
	assert !encoded.contains('env-secret-value-123')
	assert encoded.contains(trace_redaction_marker)
	assert encoded.contains('"redaction":"credentials"') || encoded.contains('redaction')
	trajectory := json2.decode[map[string]json2.Any](encoded) or { panic(err) }
	extra := (trajectory['extra'] or { json2.Any('') }).str()
	assert extra.contains('credentials')
	args := (trajectory['steps'] or { json2.Any('') }).str()
	assert args.contains('plain')
}

fn test_trace_redaction_recognizes_credential_shapes_without_env() {
	encoded := encode_atif_trace('session-1', '0.1.0', 'fixture-model', [
		ATIFStep{
			step_id: 1
			source:  'user'
			message: 'keys: sk-test-AbCdEfGh123456 and LLM_1234567890_abcdefghij; Authorization: Bearer abcdefghijklmnopqrstuvwxyz; api_key = plain-value-123; CLIENT SECRET: spaced-value-456; PASSWORD=hunter2!pass; normal code: fn main() {} and path src/main.v stays'
		},
	]) or { panic(err) }
	assert !encoded.contains('sk-test-AbCdEfGh123456')
	assert !encoded.contains('LLM_1234567890_abcdefghij')
	assert !encoded.contains('abcdefghijklmnopqrstuvwxyz')
	assert !encoded.contains('plain-value-123')
	assert !encoded.contains('spaced-value-456')
	assert !encoded.contains('hunter2!pass')
	assert encoded.contains('fn main() {}')
	assert encoded.contains('src/main.v')
}

fn test_trace_redaction_structured_secret_field_regardless_of_shape() {
	call := atif_tool_call(ProviderToolCall{
		id:       'call-9'
		function: ProviderFunctionCall{
			name:      'workspace_run'
			arguments: '{"password":"hunter2-plain","nested":{"token":"abc"},"count":3}'
		}
	}) or { panic(err) }
	encoded := encode_atif_trace('session-1', '0.1.0', 'fixture-model', [
		ATIFStep{
			step_id:    1
			source:     'agent'
			model_name: 'fixture-model'
			message:    ''
			tool_calls: [call]
		},
	]) or { panic(err) }
	assert !encoded.contains('hunter2-plain')
	assert encoded.contains('"count":3') || encoded.contains('count')
}

fn test_trace_redaction_keeps_short_env_values_and_prose() {
	os.setenv('VEASEL_TEST_API_KEY', 'short', true)
	defer { os.unsetenv('VEASEL_TEST_API_KEY') }
	encoded := encode_atif_trace('session-1', '0.1.0', 'fixture-model', [
		ATIFStep{
			step_id: 1
			source:  'user'
			message: 'A short note about token budgets and secret menus.'
		},
	]) or { panic(err) }
	assert encoded.contains('A short note about token budgets and secret menus.')
	assert !encoded.contains(trace_redaction_marker)
}

fn test_trace_redaction_replaces_a_pem_block_and_keeps_surrounding_text() {
	text := 'before\n-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\nafter'
	redacted := redact_trace_text(text, []string{})
	assert !redacted.contains('BEGIN OPENSSH')
	assert !redacted.contains('AAAA')
	assert redacted.contains('before')
	assert redacted.contains('after')
	assert redacted.contains(trace_redaction_marker)
}

fn test_trace_redaction_leaves_an_unclosed_begin_marker() {
	text := 'note -----BEGIN without an end'
	assert redact_trace_text(text, []string{}) == text
}
