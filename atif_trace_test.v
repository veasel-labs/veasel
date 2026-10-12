module main

import json2
import os
import uuid

fn test_atif_trace_encodes_tool_call_observation_links() {
	call := atif_tool_call(ProviderToolCall{
		id:       'call-1'
		function: ProviderFunctionCall{
			name:      'workspace_read_file'
			arguments: '{"path":"src/main.v"}'
		}
	}) or { panic(err) }
	encoded := encode_atif_trace('session-1', '0.1.0', 'fixture-model', [
		ATIFStep{
			step_id: 1
			source:  'user'
			message: 'Read src/main.v'
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
					content:        'module main'
				}]
			}
		},
		ATIFStep{
			step_id:    3
			source:     'agent'
			model_name: 'fixture-model'
			message:    'The file declares module main.'
		},
	]) or { panic(err) }
	mut path := os.getenv('VEASEL_ATIF_TEST_OUTPUT')
	if path.len == 0 {
		path = os.join_path(os.temp_dir(), 'veasel-atif-${uuid.new_v4().str()}.json')
		defer { os.rm(path) or {} }
	}
	os.write_file(path, encoded) or { panic(err) }
	trajectory := json2.decode[map[string]json2.Any](os.read_file(path) or { panic(err) }) or {
		panic(err)
	}
	assert trajectory['schema_version'] or { json2.Any('') } == json2.Any('ATIF-v1.8')
	assert trajectory['session_id'] or { json2.Any('') } == json2.Any('session-1')
	assert trajectory['extra'] or { json2.Any('') }.str().contains('unavailable')
	steps := json2.decode[[]map[string]json2.Any]((trajectory['steps'] or {
		json2.Any('[]')
	}).str()) or { panic(err) }
	assert steps.len == 3
	assert (steps[1]['tool_calls'] or { json2.Any('[]') }).str().contains('workspace_read_file')
	assert (steps[1]['observation'] or { json2.Any('{}') }).str().contains('call-1')
	assert !encoded.contains('cost_usd')
}

fn test_operation_trace_store_is_session_scoped_and_migrated() {
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	one := store.create_session(SessionInput{ title: 'one', directory: '/' }) or { panic(err) }
	two := store.create_session(SessionInput{ title: 'two', directory: '/' }) or { panic(err) }
	operation_id := uuid.new_v4().str()
	store.create_session_operation(one.id, operation_id) or { panic(err) }
	store.append_exchange(one.id, operation_id, 'prompt', 'response', 'fixture', 'model',
		'{"schema_version":"ATIF-v1.8"}') or {
		panic(err)
	}
	assert store.operation_trace(one.id, operation_id) or { panic(err) } == '{"schema_version":"ATIF-v1.8"}'
	assert store.operation_trace(two.id, operation_id) or { '' } == ''
	if _ := store.append_exchange(one.id, operation_id, 'duplicate prompt', 'duplicate response',
		'fixture', 'model', '{"schema_version":"ATIF-v1.8"}') {
		assert false
	}
	persisted_messages := store.messages_for_session(one.id, 10) or { panic(err) }
	assert persisted_messages.len == 2
	if _ := store.append_exchange(one.id, 'invalid', 'prompt', 'response', 'fixture', 'model',
		'{"schema_version":"ATIF-v1.8"}') {
		assert false
	} else {
		assert err.msg().contains('operation trace is invalid')
	}
}
