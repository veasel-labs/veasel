module main

import context as vcontext
import json2
import net.http
import os
import time
import uuid

struct SubagentProviderFixture {
mut:
	hits           int
	fail_child     bool
	request_bodies []string
}

fn subagent_test_chunk(hit int) OpenAIStreamChunk {
	delta := match hit {
		1 {
			OpenAIStreamDelta{
				tool_calls: [OpenAIStreamToolCallDelta{
					index:    0
					id:       'call-delegate'
					type:     'function'
					function: OpenAIStreamFunctionDelta{
						name:      'subagent_run'
						arguments: '{"agent_id":"explorer","task":"Read README.md and report the marker."}'
					}
				}]
			}
		}
		2 {
			OpenAIStreamDelta{
				tool_calls: [OpenAIStreamToolCallDelta{
					index:    0
					id:       'call-read'
					type:     'function'
					function: OpenAIStreamFunctionDelta{
						name:      'workspace_read_file'
						arguments: '{"path":"README.md"}'
					}
				}]
			}
		}
		3 { OpenAIStreamDelta{ content: 'The README marker is BLUE-MOON.' } }
		else {
			OpenAIStreamDelta{ content: 'The delegated explorer found BLUE-MOON in README.md.' }
		}
	}
	return OpenAIStreamChunk{
		choices: [OpenAIStreamChoice{
			delta: delta
		}]
		usage:   OpenAIUsage{
			prompt_tokens:     10
			completion_tokens: 3
			total_tokens:      13
		}
	}
}

fn test_subagent_truncation_respects_utf8_byte_limits() {
	assert truncate_utf8_bytes('A🙂B', 4) == 'A'
	assert truncate_utf8_bytes('A🙂B', 5) == 'A🙂'
	assert truncate_utf8_bytes('A🙂B', 0) == ''
	profile := builtin_subagent_profile('explorer') or { panic(err) }
	assert subagent_title(profile, '🙂'.repeat(200)).len <= 512
}

fn (mut fixture SubagentProviderFixture) handle(request http.Request) http.Response {
	fixture.hits++
	fixture.request_bodies << request.data
	if fixture.fail_child && fixture.hits == 2 {
		mut response := http.Response{}
		response.set_status(.internal_server_error)
		response.body = 'fixture child provider failure'
		return response
	}
	chunk := if fixture.fail_child && fixture.hits == 3 {
		OpenAIStreamChunk{
			choices: [OpenAIStreamChoice{
				delta: OpenAIStreamDelta{
					content: 'Delegated investigation failed and the error was reported safely.'
				}
			}]
			usage:   OpenAIUsage{
				prompt_tokens:     10
				completion_tokens: 3
				total_tokens:      13
			}
		}
	} else {
		subagent_test_chunk(fixture.hits)
	}
	mut response := http.Response{}
	response.set_status(.ok)
	response.header.set(.content_type, 'text/event-stream')
	response.body = 'data: ${json2.encode(chunk)}\n\ndata: [DONE]\n\n'
	return response
}

fn init_subagent_runtime_test_repo(root string) string {
	repo := os.join_path(root, 'workspace')
	os.mkdir_all(repo) or { panic(err) }
	_ := run_workspace_git_command(repo, ['init', '-b', 'main']) or { panic(err) }
	_ := run_workspace_git_command(repo, ['config', 'user.email', 'veasel@example.com']) or {
		panic(err)
	}
	_ := run_workspace_git_command(repo, ['config', 'user.name', 'Veasel']) or { panic(err) }
	os.write_file(os.join_path(repo, 'README.md'), 'base\n') or { panic(err) }
	_ := run_workspace_git_command(repo, ['add', 'README.md']) or { panic(err) }
	_ := run_workspace_git_command(repo, ['commit', '-m', 'base']) or { panic(err) }
	return repo
}

fn start_subagent_provider_fixture(mut fixture SubagentProviderFixture) !(&http.Server, thread) {
	mut server := &http.Server{
		accept_timeout:       100 * time.millisecond
		handler:              fixture
		addr:                 '127.0.0.1:0'
		show_startup_message: false
	}
	server_thread := spawn server.listen_and_serve()
	server.wait_till_running() or {
		server.stop()
		server_thread.wait()
		return error(err.msg())
	}
	return server, server_thread
}

fn test_model_callable_subagent_reads_in_isolated_workspace_and_persists_usage() {
	root := os.join_path(os.temp_dir(), 'veasel-subagent-provider-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	workspace := init_subagent_runtime_test_repo(root)
	os.write_file(os.join_path(workspace, 'README.md'), 'marker: BLUE-MOON\n') or { panic(err) }
	os.mkdir_all(os.join_path(root, 'data')) or { panic(err) }
	os.mkdir_all(os.join_path(root, 'plugins')) or { panic(err) }
	mut fixture := &SubagentProviderFixture{}
	mut server, server_thread := start_subagent_provider_fixture(mut fixture) or { panic(err) }
	defer {
		server.stop()
		server_thread.wait()
	}
	mut store := open_store(os.join_path(root, 'data', 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	mut app := new_app(store, os.join_path(root, 'plugins'))
	defer { app.close() }
	app.model_settings.update(ModelSettingsInput{
		provider: 'openai-compatible'
		model:    'local-fixture'
		base_url: 'http://${server.addr}/v1'
		api_key:  'fixture-only'
	}) or { panic(err) }
	parent := store.create_session(SessionInput{
		title:     'Parent investigation'
		directory: workspace
	}) or { panic(err) }
	operation_id := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, operation_id) or { panic(err) }
	mut background := vcontext.background()
	mut turn_ctx, cancel := vcontext.with_timeout(mut background, 15 * time.second)
	defer { cancel() }
	exchange := app.run_session_message(mut turn_ctx, parent.id, parent, ChatMessageInput{
		content: 'Find the README marker. Delegate the focused file inspection.'
	}, operation_id) or { panic(err) }
	assert exchange.messages.len == 2
	assert exchange.messages[1].content == 'The delegated explorer found BLUE-MOON in README.md.'
	assert fixture.hits == 4
	assert fixture.request_bodies[0].contains('subagent_run')
	assert fixture.request_bodies[1].contains('workspace_read_file')
	assert !fixture.request_bodies[1].contains('workspace_propose_shell_command')
	assert fixture.request_bodies[2].contains('marker: BLUE-MOON')
	child_rows := store.db.exec_param_many('SELECT id, child_session_id, status, result, outcome_claimed FROM subagent_runs WHERE parent_session_id = ? AND parent_operation_id = ?',
		[parent.id, operation_id]) or { panic(err) }
	assert child_rows.len == 1
	assert child_rows[0].val(2) == 'completed'
	assert child_rows[0].val(3) == 'The README marker is BLUE-MOON.'
	assert child_rows[0].val(4).int() == 1
	child_session := store.get_session(child_rows[0].val(1)) or { panic(err) }
	child_messages := store.messages_for_session(child_session.id, max_chat_messages) or { panic(err) }
	assert child_messages.len == 2
	assert child_messages[1].content == 'The README marker is BLUE-MOON.'
	child_operation := store.db.exec_param_many('SELECT input_tokens, output_tokens FROM session_operations WHERE session_id = ?',
		[child_session.id]) or { panic(err) }
	assert child_operation.len == 1
	assert child_operation[0].val(0).int() == 20
	assert child_operation[0].val(1).int() == 6
	assert os.read_file(os.join_path(workspace, 'README.md')) or { panic(err) } == 'marker: BLUE-MOON\n'
}

fn test_model_callable_subagent_delivers_child_provider_failure_to_parent() {
	root := os.join_path(os.temp_dir(), 'veasel-subagent-failure-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	workspace := init_subagent_runtime_test_repo(root)
	os.mkdir_all(os.join_path(root, 'data')) or { panic(err) }
	os.mkdir_all(os.join_path(root, 'plugins')) or { panic(err) }
	mut fixture := &SubagentProviderFixture{
		fail_child: true
	}
	mut server, server_thread := start_subagent_provider_fixture(mut fixture) or { panic(err) }
	defer {
		server.stop()
		server_thread.wait()
	}
	mut store := open_store(os.join_path(root, 'data', 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	mut app := new_app(store, os.join_path(root, 'plugins'))
	defer { app.close() }
	app.model_settings.update(ModelSettingsInput{
		provider: 'openai-compatible'
		model:    'local-fixture'
		base_url: 'http://${server.addr}/v1'
		api_key:  'fixture-only'
	}) or { panic(err) }
	parent := store.create_session(SessionInput{
		title:     'Parent failure investigation'
		directory: workspace
	}) or { panic(err) }
	operation_id := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, operation_id) or { panic(err) }
	mut background := vcontext.background()
	mut turn_ctx, cancel := vcontext.with_timeout(mut background, 15 * time.second)
	defer { cancel() }
	exchange := app.run_session_message(mut turn_ctx, parent.id, parent, ChatMessageInput{
		content: 'Investigate a failure in a delegated read-only investigation.'
	}, operation_id) or { panic(err) }
	assert exchange.messages.len == 2
	assert exchange.messages[1].content == 'Delegated investigation failed and the error was reported safely.'
	assert fixture.hits == 3
	child_rows := store.db.exec_param_many('SELECT child_session_id, status, error, outcome_claimed FROM subagent_runs WHERE parent_session_id = ? AND parent_operation_id = ?',
		[parent.id, operation_id]) or { panic(err) }
	assert child_rows.len == 1
	assert child_rows[0].val(1) == 'failed'
	assert child_rows[0].val(2) == 'HTTP 500'
	assert child_rows[0].val(3).int() == 1
	assert fixture.request_bodies[2].contains('The read-only investigation failed.')
	assert !fixture.request_bodies[2].contains('HTTP 500')
	child_operation := store.db.exec_param_many('SELECT status, error FROM session_operations WHERE session_id = ?',
		[child_rows[0].val(0)]) or { panic(err) }
	assert child_operation.len == 1
	assert child_operation[0].val(0) == 'failed'
	assert child_operation[0].val(1) == 'HTTP 500'
}

fn test_model_callable_subagent_persists_parent_cancellation() {
	root := os.join_path(os.temp_dir(), 'veasel-subagent-cancel-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	workspace := init_subagent_runtime_test_repo(root)
	os.mkdir_all(os.join_path(root, 'data')) or { panic(err) }
	os.mkdir_all(os.join_path(root, 'plugins')) or { panic(err) }
	mut fixture := &SubagentProviderFixture{}
	mut server, server_thread := start_subagent_provider_fixture(mut fixture) or { panic(err) }
	defer {
		server.stop()
		server_thread.wait()
	}
	mut store := open_store(os.join_path(root, 'data', 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	mut app := new_app(store, os.join_path(root, 'plugins'))
	defer { app.close() }
	app.model_settings.update(ModelSettingsInput{
		provider: 'openai-compatible'
		model:    'local-fixture'
		base_url: 'http://${server.addr}/v1'
		api_key:  'fixture-only'
	}) or { panic(err) }
	parent := store.create_session(SessionInput{
		title:     'Parent cancellation investigation'
		directory: workspace
	}) or { panic(err) }
	operation_id := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, operation_id) or { panic(err) }
	mut background := vcontext.background()
	mut turn_ctx, cancel := vcontext.with_cancel(mut background)
	cancel()
	result := app.execute_subagent_run(mut turn_ctx, workspace, parent.id, operation_id,
		ProviderToolCall{
			id:       'call-cancel'
			function: ProviderFunctionCall{
				name:      'subagent_run'
				arguments: '{"agent_id":"explorer","task":"Read README.md."}'
			}
		}) or { panic(err) }
	tool_result := json2.decode[SubagentToolResult](result) or { panic(err) }
	assert tool_result.status == 'cancelled'
	assert tool_result.error == 'The parent operation cancelled this investigation.'
	assert fixture.hits == 0
	child_rows := store.db.exec_param_many('SELECT id, child_session_id, status, outcome_claimed, workspace_started FROM subagent_runs WHERE parent_session_id = ? AND parent_operation_id = ?',
		[parent.id, operation_id]) or { panic(err) }
	assert child_rows.len == 1
	assert child_rows[0].val(2) == 'cancelled'
	assert child_rows[0].val(3).int() == 1
	assert child_rows[0].val(4).int() == 0
	child_workspace := os.join_path(root, 'data', 'subagent-worktrees', child_rows[0].val(0))
	assert !os.exists(child_workspace)
	child_operation := store.db.exec_param_many('SELECT status FROM session_operations WHERE session_id = ?',
		[child_rows[0].val(1)]) or { panic(err) }
	assert child_operation.len == 0
}
