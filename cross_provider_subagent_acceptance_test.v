module main

import context as vcontext
import json2
import net.http
import os
import sync
import time
import uuid

// These fixtures exercise the real provider adapters through the durable
// subagent runtime. Each handler blocks after receiving its adapter-specific
// request so the test can prove that independent children overlap in flight.
struct CrossProviderFixture {
	protocol string
mut:
	mu          sync.Mutex
	hits        int
	path        string
	body        string
	auth_header string
	api_key     string
	started     chan bool
	release     chan bool
}

fn (mut fixture CrossProviderFixture) handle(request http.Request) http.Response {
	fixture.mu.lock()
	fixture.hits++
	fixture.path = request.url
	fixture.body = request.data
	fixture.auth_header = request.header.get_custom('Authorization') or { '' }
	fixture.api_key = match fixture.protocol {
		'anthropic' { request.header.get_custom('x-api-key') or { '' } }
		'gemini' { request.header.get_custom('x-goog-api-key') or { '' } }
		else { '' }
	}
	fixture.mu.unlock()
	fixture.started <- true
	_ := <-fixture.release
	mut response := http.Response{}
	response.set_status(.ok)
	response.header.set(.content_type, 'text/event-stream')
	response.body = match fixture.protocol {
		'anthropic' {
			[
				'event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":5}}}\n\n',
				'event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n',
				'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"anthropic child verified"}}\n\n',
				'event: message_delta\ndata: {"type":"message_delta","usage":{"output_tokens":3}}\n\n',
				'event: message_stop\ndata: {"type":"message_stop"}\n\n',
			].join('')
		}
		'gemini' {
			'data: {"candidates":[{"content":{"parts":[{"text":"gemini child verified"}]}}],"usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":4,"totalTokenCount":11}}\n\n'
		}
		else { '' }
	}
	return response
}

fn start_cross_provider_fixture(mut fixture CrossProviderFixture) !(&http.Server, thread) {
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

fn init_cross_provider_workspace(root string) string {
	repo := os.join_path(root, 'workspace')
	os.mkdir_all(repo) or { panic(err) }
	_ := run_workspace_git_command(repo, ['init', '-b', 'main']) or { panic(err) }
	_ := run_workspace_git_command(repo, ['config', 'user.email', 'veasel@example.com']) or {
		panic(err)
	}
	_ := run_workspace_git_command(repo, ['config', 'user.name', 'Veasel']) or { panic(err) }
	os.write_file(os.join_path(repo, 'README.md'), 'fixture README\n') or { panic(err) }
	_ := run_workspace_git_command(repo, ['add', 'README.md']) or { panic(err) }
	_ := run_workspace_git_command(repo, ['commit', '-m', 'base']) or { panic(err) }
	return repo
}

fn wait_for_cross_provider_run(mut store Store, run_id string) SubagentRun {
	deadline := time.sys_mono_now() + u64(10 * time.second)
	for time.sys_mono_now() < deadline {
		run := store.get_subagent_run(run_id) or { panic(err) }
		if run.status in ['completed', 'failed', 'cancelled', 'uncertain'] {
			return run
		}
		time.sleep(10 * time.millisecond)
	}
	panic('timed out waiting for cross-provider child ${run_id}')
}

fn wait_for_cross_provider_request(started chan bool, provider string) {
	deadline := time.sys_mono_now() + u64(5 * time.second)
	mut received := false
	for time.sys_mono_now() < deadline {
		if started.try_pop(mut received) == .success {
			return
		}
		time.sleep(10 * time.millisecond)
	}
	panic('${provider} adapter did not start')
}

fn test_concurrent_subagents_use_distinct_provider_adapters_and_persist_attributed_results() {
	root := os.join_path(os.temp_dir(), 'veasel-cross-provider-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	workspace := init_cross_provider_workspace(root)
	os.mkdir_all(os.join_path(root, 'data')) or { panic(err) }
	os.mkdir_all(os.join_path(root, 'plugins')) or { panic(err) }
	mut anthropic_fixture := &CrossProviderFixture{
		protocol: 'anthropic'
		started:  chan bool{cap: 1}
		release:  chan bool{cap: 1}
	}
	mut gemini_fixture := &CrossProviderFixture{
		protocol: 'gemini'
		started:  chan bool{cap: 1}
		release:  chan bool{cap: 1}
	}
	mut anthropic_server, anthropic_thread := start_cross_provider_fixture(mut anthropic_fixture) or {
		panic(err)
	}
	mut gemini_server, gemini_thread := start_cross_provider_fixture(mut gemini_fixture) or {
		anthropic_server.stop()
		anthropic_thread.wait()
		panic(err)
	}
	defer {
		_ = anthropic_fixture.release.try_push(true)
		_ = gemini_fixture.release.try_push(true)
		anthropic_server.stop()
		gemini_server.stop()
		anthropic_thread.wait()
		gemini_thread.wait()
	}
	mut store := open_store(os.join_path(root, 'data', 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	mut app := new_app(store, os.join_path(root, 'plugins'))
	defer { app.close() }
	// Release blocked provider handlers before app.close waits for child workers,
	// including when an assertion above fails.
	defer {
		_ = anthropic_fixture.release.try_push(true)
		_ = gemini_fixture.release.try_push(true)
	}
	app.model_settings.update(ModelSettingsInput{
		provider: 'anthropic'
		model:    'fixture-anthropic-model'
		base_url: 'http://${anthropic_server.addr}'
		api_key:  'anthropic-fixture-secret'
	}) or { panic(err) }
	app.model_settings.update(ModelSettingsInput{
		provider: 'gemini'
		model:    'fixture-gemini-model'
		base_url: 'http://${gemini_server.addr}/v1beta'
		api_key:  'gemini-fixture-secret'
	}) or { panic(err) }
	parent := store.create_session(SessionInput{
		title:     'Cross-provider parent'
		directory: workspace
	}) or { panic(err) }
	operation_id := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, operation_id) or { panic(err) }

	first := app.delegate_subagent_task(parent.id, operation_id, 'request-anthropic', 'explorer',
		'Inspect the README and return a concise finding.', 'anthropic', 'fixture-anthropic-model') or {
		panic(err)
	}
	second := app.delegate_subagent_task(parent.id, operation_id, 'request-gemini', 'reviewer',
		'Review the repository entry point and return a concise finding.', 'gemini', 'fixture-gemini-model') or {
		panic(err)
	}
	assert first.status == 'running'
	assert second.status == 'running'

	// Both provider handlers must have accepted their own requests while neither
	// response has been released. This proves actual overlap, not queued metadata.
	wait_for_cross_provider_request(anthropic_fixture.started, 'Anthropic')
	wait_for_cross_provider_request(gemini_fixture.started, 'Gemini while Anthropic is blocked')
	assert anthropic_fixture.hits == 1
	assert gemini_fixture.hits == 1
	assert anthropic_fixture.path == '/messages'
	assert gemini_fixture.path == '/v1beta/models/fixture-gemini-model:streamGenerateContent?alt=sse'
	assert anthropic_fixture.api_key == 'anthropic-fixture-secret'
	assert anthropic_fixture.auth_header == ''
	assert gemini_fixture.api_key == 'gemini-fixture-secret'
	assert gemini_fixture.auth_header == ''
	assert anthropic_fixture.body.contains('fixture-anthropic-model')
	assert gemini_fixture.path.contains('/v1beta/models/fixture-gemini-model:streamGenerateContent')
	assert !anthropic_fixture.body.contains('workspace_propose_file_edit')
	assert !anthropic_fixture.body.contains('workspace_propose_shell_command')
	assert !gemini_fixture.body.contains('workspace_propose_file_edit')
	assert !gemini_fixture.body.contains('workspace_propose_shell_command')

	// Cancelling one blocked provider call must not cancel the other provider.
	cancelled_request := app.cancel_subagent_run(parent.id, first.id) or { panic(err) }
	assert cancelled_request.cancel_requested
	time.sleep(250 * time.millisecond)
	anthropic_fixture.release <- true
	interrupted_anthropic := wait_for_cross_provider_run(mut store, first.id)
	assert interrupted_anthropic.status == 'cancelled'
	assert interrupted_anthropic.provider == 'anthropic'
	assert interrupted_anthropic.model == 'fixture-anthropic-model'
	assert interrupted_anthropic.cancel_requested
	assert interrupted_anthropic.outcome_claimed
	assert store.get_subagent_run(second.id) or { panic(err) }.status == 'running'

	gemini_fixture.release <- true
	gemini_run := wait_for_cross_provider_run(mut store, second.id)
	assert gemini_run.status == 'completed'
	assert gemini_run.provider == 'gemini'
	assert gemini_run.model == 'fixture-gemini-model'
	assert gemini_run.result.contains('gemini child verified')
	assert gemini_run.usage_reported
	assert gemini_run.input_tokens == 7
	assert gemini_run.output_tokens == 4
	assert interrupted_anthropic.parent_session_id == parent.id
	assert gemini_run.parent_session_id == parent.id
	assert gemini_run.outcome_claimed
	mut background := vcontext.background()
	mut wait_ctx, cancel_wait := vcontext.with_timeout(mut background, 2 * time.second)
	defer { cancel_wait() }
	parent_result_json := app.execute_subagent_wait(mut wait_ctx, parent.id, operation_id,
		ProviderToolCall{
			function: ProviderFunctionCall{
				name:      'subagent_wait'
				arguments: '{"run_id":"${second.id}","wait_ms":0}'
			}
		}) or { panic(err) }
	parent_result := json2.decode[SubagentToolResult](parent_result_json) or { panic(err) }
	assert parent_result.status == 'completed'
	assert parent_result.provider == 'gemini'
	assert parent_result.model == 'fixture-gemini-model'
	assert parent_result.result == gemini_run.result
	assert parent_result.usage_reported
	assert parent_result.input_tokens == 7
	assert parent_result.output_tokens == 4
}
