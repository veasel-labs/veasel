module main

import context as vcontext
import json2
import net.http
import os
import sync
import time
import uuid

struct SubagentProviderFixture {
mut:
	mu                          sync.Mutex
	hits                        int
	parent_hits                 int
	child_hits                  int
	fail_child                  bool
	pause_child_until_released  bool
	pause_parent_until_released bool
	child_request_started       chan bool
	release_child_request       chan bool
	parent_request_started      chan bool
	release_parent_request      chan bool
	request_bodies              []string
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
	fixture.mu.lock()
	fixture.hits++
	is_child := request.data.contains('You are a read-only Veasel Code')
	mut hit := 0
	if is_child {
		fixture.child_hits++
		hit = fixture.child_hits
	} else {
		fixture.parent_hits++
		hit = fixture.parent_hits
	}
	fixture.request_bodies << request.data
	pause_child := fixture.pause_child_until_released && is_child && hit == 1
	pause_parent := fixture.pause_parent_until_released && !is_child && hit == 2
	fail_child := fixture.fail_child && is_child
	fixture.mu.unlock()
	if pause_child {
		fixture.child_request_started <- true
		_ := <-fixture.release_child_request
	}
	if pause_parent {
		fixture.parent_request_started <- true
		_ := <-fixture.release_parent_request
	}
	if fail_child {
		mut response := http.Response{}
		response.set_status(.internal_server_error)
		response.body = 'fixture child provider failure'
		return response
	}
	chunk := if is_child && hit == 1 {
		subagent_test_chunk(2)
	} else if is_child {
		subagent_test_chunk(3)
	} else if hit == 1 {
		subagent_test_chunk(1)
	} else {
		OpenAIStreamChunk{
			choices: [OpenAIStreamChoice{
				delta: OpenAIStreamDelta{ content: 'The parent started a delegated investigation.' }
			}]
		}
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

fn wait_for_subagent_terminal(mut store Store, run_id string) SubagentRun {
	deadline := time.sys_mono_now() + u64(10 * time.second)
	for time.sys_mono_now() < deadline {
		run := store.get_subagent_run(run_id) or { panic(err) }
		if run.status in ['completed', 'failed', 'cancelled', 'uncertain'] {
			return run
		}
		time.sleep(10 * time.millisecond)
	}
	panic('timed out waiting for child run ${run_id}')
}

fn wait_for_subagent_outcome_claimed(mut store Store, run_id string) SubagentRun {
	deadline := time.sys_mono_now() + u64(10 * time.second)
	for time.sys_mono_now() < deadline {
		run := store.get_subagent_run(run_id) or { panic(err) }
		if run.outcome_claimed {
			return run
		}
		time.sleep(10 * time.millisecond)
	}
	panic('timed out waiting for child outcome ${run_id}')
}

fn test_model_callable_subagent_reads_in_isolated_workspace_and_persists_usage() {
	root := os.join_path(os.temp_dir(), 'veasel-subagent-provider-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	workspace := init_subagent_runtime_test_repo(root)
	os.write_file(os.join_path(workspace, 'README.md'), 'marker: BLUE-MOON\n') or { panic(err) }
	_ := run_workspace_git_command(workspace, ['add', 'README.md']) or { panic(err) }
	_ := run_workspace_git_command(workspace, ['commit', '-m', 'add marker fixture']) or { panic(err) }
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
	}, operation_id, turn_ctx.deadline() or { panic('expected a turn deadline') }) or { panic(err) }
	assert exchange.messages.len == 2
	assert exchange.messages[1].content == 'The parent started a delegated investigation.'
	child_rows := store.db.exec_param_many('SELECT id, child_session_id, status, result, outcome_claimed FROM subagent_runs WHERE parent_session_id = ? AND parent_operation_id = ?',
		[parent.id, operation_id]) or { panic(err) }
	assert child_rows.len == 1
	completed_run := wait_for_subagent_terminal(mut store, child_rows[0].val(0))
	assert fixture.parent_hits == 2
	assert fixture.child_hits == 2
	assert completed_run.status == 'completed'
	assert completed_run.result == 'The README marker is BLUE-MOON.'
	assert completed_run.outcome_claimed
	mut wait_background := vcontext.background()
	mut wait_ctx, wait_cancel := vcontext.with_timeout(mut wait_background, 2 * time.second)
	defer { wait_cancel() }
	wait_json := app.execute_subagent_wait(mut wait_ctx, parent.id, operation_id, ProviderToolCall{
		function: ProviderFunctionCall{
			name:      'subagent_wait'
			arguments: '{"run_id":"${completed_run.id}","wait_ms":1000}'
		}
	}) or { panic(err) }
	wait_result := json2.decode[SubagentToolResult](wait_json) or { panic(err) }
	assert wait_result.status == 'completed'
	assert wait_result.result == completed_run.result
	assert wait_result.provider == completed_run.provider
	assert wait_result.model == completed_run.model
	assert wait_result.usage_reported == completed_run.usage_reported
	assert wait_result.input_tokens == completed_run.input_tokens
	assert wait_result.output_tokens == completed_run.output_tokens
	mut saw_child_request := false
	mut saw_workspace_read := false
	mut saw_marker_context := false
	for body in fixture.request_bodies {
		if body.contains('You are a read-only Veasel Code') {
			saw_child_request = true
		}
		if body.contains('workspace_read_file') {
			saw_workspace_read = true
		}
		if body.contains('marker: BLUE-MOON') {
			saw_marker_context = true
		}
	}
	assert saw_child_request
	assert saw_workspace_read
	assert saw_marker_context
	// The app cleanup may defer when the parent turn still owns the child's
	// striped session lock. Once the parent exchange has returned, startup's
	// durable cleanup path should reclaim this unchanged read-only worktree.
	worktree_path := os.join_path(root, 'data', 'subagent-worktrees', completed_run.id)
	assert completed_run.workspace_ready
	assert completed_run.workspace_started
	assert subagent_workspace_is_unchanged(workspace, worktree_path, completed_run.id,
		completed_run.workspace_base_commit)
	cleanup_deadline := time.sys_mono_now() + u64(3 * time.second)
	mut child_session := store.get_session(child_rows[0].val(1)) or { panic(err) }
	for (os.exists(worktree_path) || child_session.directory != workspace)
		&& time.sys_mono_now() < cleanup_deadline {
		store.cleanup_delivered_subagent_workspaces()
		child_session = store.get_session(child_rows[0].val(1)) or { panic(err) }
		time.sleep(50 * time.millisecond)
	}
	assert !os.exists(worktree_path)
	assert child_session.directory == workspace
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
	}, operation_id, turn_ctx.deadline() or { panic('expected a turn deadline') }) or { panic(err) }
	assert exchange.messages.len == 2
	assert exchange.messages[1].content == 'The parent started a delegated investigation.'
	child_rows := store.db.exec_param_many('SELECT id, child_session_id FROM subagent_runs WHERE parent_session_id = ? AND parent_operation_id = ?',
		[parent.id, operation_id]) or { panic(err) }
	assert child_rows.len == 1
	failed_run := wait_for_subagent_outcome_claimed(mut store, child_rows[0].val(0))
	assert fixture.parent_hits == 2
	assert fixture.child_hits >= 1
	assert fixture.child_hits <= 1 + provider_transient_retry_delays_ms.len
	assert failed_run.status == 'failed'
	assert failed_run.error == 'HTTP 500'
	assert failed_run.outcome_claimed
	for body in fixture.request_bodies {
		assert !body.contains('HTTP 500')
	}
	child_operation := store.db.exec_param_many('SELECT status, error FROM session_operations WHERE session_id = ?',
		[child_rows[0].val(1)]) or { panic(err) }
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
	assert result.contains('cancelled')
	assert fixture.hits == 0
	child_rows := store.db.exec_param_many('SELECT id, child_session_id, status, outcome_claimed, workspace_started, workspace_ready FROM subagent_runs WHERE parent_session_id = ? AND parent_operation_id = ?',
		[parent.id, operation_id]) or { panic(err) }
	assert child_rows.len == 0
}

fn test_model_callable_subagent_child_cancellation_returns_while_http_is_waiting() {
	root := os.join_path(os.temp_dir(), 'veasel-subagent-inflight-cancel-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	workspace := init_subagent_runtime_test_repo(root)
	os.mkdir_all(os.join_path(root, 'data')) or { panic(err) }
	os.mkdir_all(os.join_path(root, 'plugins')) or { panic(err) }
	mut fixture := &SubagentProviderFixture{
		pause_child_until_released:  true
		child_request_started:       chan bool{cap: 1}
		release_child_request:       chan bool{cap: 1}
		parent_request_started:      chan bool{cap: 1}
		release_parent_request:      chan bool{cap: 1}
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
	defer {
		_ = fixture.release_child_request.try_push(true)
		_ = fixture.release_parent_request.try_push(true)
	}
	app.model_settings.update(ModelSettingsInput{
		provider: 'openai-compatible'
		model:    'local-fixture'
		base_url: 'http://${server.addr}/v1'
		api_key:  'fixture-only'
	}) or { panic(err) }
	parent := store.create_session(SessionInput{
		title:     'Parent in-flight cancellation'
		directory: workspace
	}) or { panic(err) }
	operation_id := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, operation_id) or { panic(err) }
	mut background := vcontext.background()
	mut turn_ctx, cancel := vcontext.with_timeout(mut background, 15 * time.second)
	result_chan := chan string{cap: 1}
	spawn fn (app &App, turn_ctx vcontext.Context, parent Session, operation_id string,
		result_chan chan string) {
		mut worker_ctx := turn_ctx
		_ = app.run_session_message(mut worker_ctx, parent.id, parent, ChatMessageInput{
			content: 'Delegate a focused investigation, then report its result.'
		}, operation_id, worker_ctx.deadline() or { panic('expected a turn deadline') }) or {
			result_chan <- err.msg()
			return
		}
		result_chan <- 'completed'
	}(app, turn_ctx, parent, operation_id, result_chan)
	mut child_request_started := false
	start_deadline := time.sys_mono_now() + u64(10 * time.second)
	for !child_request_started && time.sys_mono_now() < start_deadline {
		if fixture.child_request_started.try_pop(mut child_request_started) != .success {
			time.sleep(10 * time.millisecond)
		}
	}
	assert child_request_started, 'expected the delegated provider request to be in flight'
	child_id_rows := store.db.exec_param_many('SELECT id FROM subagent_runs WHERE parent_session_id = ? AND parent_operation_id = ?',
		[parent.id, operation_id]) or { panic(err) }
	assert child_id_rows.len == 1
	mut wait_background := vcontext.background()
	mut wait_ctx, wait_cancel := vcontext.with_timeout(mut wait_background, time.second)
	wait_json := app.execute_subagent_wait(mut wait_ctx, parent.id, operation_id, ProviderToolCall{
		function: ProviderFunctionCall{
			name:      'subagent_wait'
			arguments: '{"run_id":"${child_id_rows[0].val(0)}","wait_ms":0}'
		}
	}) or { panic(err) }
	wait_result := json2.decode[SubagentToolResult](wait_json) or { panic(err) }
	assert wait_result.status == 'running'
	assert wait_result.result == ''
	assert !wait_result.wait_interrupted
	wait_cancel()
	cancelled_child := app.cancel_subagent_run(parent.id, child_id_rows[0].val(0)) or { panic(err) }
	assert cancelled_child.cancel_requested
	fixture.release_child_request <- true
	fixture.release_parent_request <- true
	mut parent_result := ''
	result_deadline := time.sys_mono_now() + u64(2 * time.second)
	for parent_result.len == 0 && time.sys_mono_now() < result_deadline {
		if result_chan.try_pop(mut parent_result) != .success {
			time.sleep(10 * time.millisecond)
		}
	}
	assert parent_result == 'completed', 'parent should finish independently of the cancelled child'
	child_rows := store.db.exec_param_many('SELECT status, error, outcome_claimed, id FROM subagent_runs WHERE parent_session_id = ? AND parent_operation_id = ?', [
		parent.id,
		operation_id,
	]) or { panic(err) }
	assert child_rows.len == 1
	child_run := wait_for_subagent_outcome_claimed(mut store, child_rows[0].val(3))
	assert child_run.status == 'cancelled'
	assert child_run.cancel_requested
	assert child_run.outcome_claimed
}
