module main

import json2
import net
import net.http
import os
import sync
import time
import uuid
import veb

// These loopback providers exercise the native provider adapters over actual
// HTTP. They are deterministic protocol fixtures, not real-model evidence.
struct RoutedProviderFixture {
mut:
	mu            sync.Mutex
	path          string
	body          string
	model         string
	started       chan bool
	release       chan bool
	block         bool
	protocol      string
	response_text string
	request_count int
	release_sent  bool
}

// A release token is sent at most once per fixture. This keeps deferred
// cleanup non-blocking when a scenario already released a handler.
fn release_routed_provider_fixture(mut fixture RoutedProviderFixture) {
	if fixture.release_sent {
		return
	}
	fixture.release_sent = true
	fixture.release <- true
}

fn (mut fixture RoutedProviderFixture) handle(request http.Request) http.Response {
	return if fixture.protocol == 'anthropic' {
		fixture.handle_anthropic(request)
	} else {
		fixture.handle_openai(request)
	}
}

fn (mut fixture RoutedProviderFixture) handle_openai(request http.Request) http.Response {
	fixture.mu.lock()
	fixture.path = request.url
	fixture.body = request.data
	fixture.request_count++
	request_json := json2.decode[map[string]json2.Any](request.data) or { map[string]json2.Any{} }
	fixture.model = (request_json['model'] or { json2.Any('') }).str()
	block := fixture.block
	fixture.mu.unlock()
	if block {
		fixture.started <- true
		_ := <-fixture.release
	}
	chunk := OpenAIStreamChunk{
		choices: [OpenAIStreamChoice{
			delta: OpenAIStreamDelta{ content: fixture.response_text }
		}]
		usage:   OpenAIUsage{
			prompt_tokens:     11
			completion_tokens: 4
			total_tokens:      15
		}
	}
	mut response := http.Response{}
	response.set_status(.ok)
	response.header.set(.content_type, 'text/event-stream')
	response.body = 'data: ${json2.encode(chunk)}\n\ndata: [DONE]\n\n'
	return response
}

fn (mut fixture RoutedProviderFixture) handle_anthropic(request http.Request) http.Response {
	fixture.mu.lock()
	fixture.path = request.url
	fixture.body = request.data
	fixture.request_count++
	request_json := json2.decode[map[string]json2.Any](request.data) or { map[string]json2.Any{} }
	fixture.model = (request_json['model'] or { json2.Any('') }).str()
	block := fixture.block
	fixture.mu.unlock()
	if block {
		fixture.started <- true
		_ := <-fixture.release
	}
	body := '{"type":"message_start","message":{"usage":{"input_tokens":9,"output_tokens":0}}}'
	content_start := '{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}'
	content_delta := '{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"${fixture.response_text}"}}'
	message_delta := '{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}'
	response_body := 'event: message_start\ndata: ${body}\n\nevent: content_block_start\ndata: ${content_start}\n\nevent: content_block_delta\ndata: ${content_delta}\n\nevent: message_delta\ndata: ${message_delta}\n\nevent: message_stop\ndata: {"type":"message_stop"}\n\n'
	mut response := http.Response{}
	response.set_status(.ok)
	response.header.set(.content_type, 'text/event-stream')
	response.body = response_body
	return response
}

fn start_routed_openai_fixture(mut fixture RoutedProviderFixture) !(&http.Server, thread) {
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

fn start_routed_anthropic_fixture(mut fixture RoutedProviderFixture) !(&http.Server, thread) {
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

struct SubagentHTTPServer {
	app          &App
	port         int
	server_ready chan &veb.Server
}

pub fn (mut app SubagentHTTPServer) init_server(server &veb.Server) {
	app.server_ready <- server
}

@['/v1/sessions/:id/subagents'; post]
pub fn (mut app SubagentHTTPServer) create_subagent(mut ctx Context, id string) veb.Result {
	return app.app.create_session_subagent(mut ctx, id)
}

@['/v1/sessions/:id/subagents'; get]
pub fn (mut app SubagentHTTPServer) list_subagents(mut ctx Context, id string) veb.Result {
	return app.app.list_session_subagents(mut ctx, id)
}

@['/v1/sessions/:id/subagents/:run_id'; get]
pub fn (mut app SubagentHTTPServer) get_subagent(mut ctx Context, id string, run_id string) veb.Result {
	return app.app.get_session_subagent(mut ctx, id, run_id)
}

@['/v1/sessions/:id/subagents/:run_id/cancel'; post]
pub fn (mut app SubagentHTTPServer) cancel_subagent(mut ctx Context, id string, run_id string) veb.Result {
	return app.app.cancel_session_subagent(mut ctx, id, run_id)
}

@['/v1/sessions/:id/subagents/:run_id/integrate'; post]
pub fn (mut app SubagentHTTPServer) integrate_subagent(mut ctx Context, id string, run_id string) veb.Result {
	return app.app.integrate_session_subagent(mut ctx, id, run_id)
}

fn run_subagent_http_test_server(mut app SubagentHTTPServer) {
	veb.run_at[SubagentHTTPServer, Context](mut app, host: '127.0.0.1', family: .ip, port: app.port) or {
		panic(err)
	}
}

fn wait_for_http_subagent(url string, run_id string) SubagentRun {
	deadline := time.sys_mono_now() + u64(20 * time.second)
	for time.sys_mono_now() < deadline {
		response := http.get('${url}/${run_id}') or {
			time.sleep(10 * time.millisecond)
			continue
		}
		if response.status_code == 200 {
			run := json2.decode[SubagentRun](response.body) or { panic(err) }
			if run.status in ['completed', 'failed', 'cancelled', 'uncertain'] {
				return run
			}
		}
		time.sleep(10 * time.millisecond)
	}
	panic('timed out waiting for HTTP child ${run_id}')
}

fn create_http_subagent(base_url string, request_id string, agent_id string, provider string,
	model string) SubagentRun {
	payload := json2.encode(SubagentCreateInput{
		request_id: request_id
		agent_id:   agent_id
		task:       'Return the configured fixture result and no other work.'
		target:     ?SubagentTargetInput(SubagentTargetInput{
			provider: provider
			model:    model
		})
	})
	response := http.fetch(
		url:           base_url
		method:        .post
		data:          payload
		read_timeout:  5 * time.second
		write_timeout: 5 * time.second
	) or { panic(err) }
	assert response.status_code == 202
	return json2.decode[SubagentRun](response.body) or { panic(err) }
}

fn test_http_subagents_route_native_providers_concurrently_and_cancel_independently() {
	run_http_subagents_provider_scenario(true)
}

fn test_http_subagents_complete_concurrently_on_distinct_native_providers() {
	run_http_subagents_provider_scenario(false)
}

fn run_http_subagents_provider_scenario(cancel_openai bool) {
	root := os.join_path(os.temp_dir(), 'veasel-subagent-http-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	workspace := os.join_path(root, 'workspace')
	os.mkdir_all(workspace) or { panic(err) }
	_ := run_workspace_git_command(workspace, ['init', '-b', 'main']) or { panic(err) }
	_ := run_workspace_git_command(workspace, ['config', 'user.email', 'veasel@example.com']) or { panic(err) }
	_ := run_workspace_git_command(workspace, ['config', 'user.name', 'Veasel']) or { panic(err) }
	os.write_file(os.join_path(workspace, 'README.md'), 'fixture workspace\n') or { panic(err) }
	_ := run_workspace_git_command(workspace, ['add', 'README.md']) or { panic(err) }
	_ := run_workspace_git_command(workspace, ['commit', '-m', 'fixture base']) or { panic(err) }

	mut openai_fixture := RoutedProviderFixture{
		started:       chan bool{cap: 1}
		release:       chan bool{cap: 1}
		block:         true
		protocol:      'openai-compatible'
		response_text: 'OPENAI-CHILD-RESULT'
	}
	mut anthropic_fixture := RoutedProviderFixture{
		started:       chan bool{cap: 1}
		release:       chan bool{cap: 1}
		block:         true
		protocol:      'anthropic'
		response_text: 'ANTHROPIC-CHILD-RESULT'
	}
	mut openai_server, openai_thread := start_routed_openai_fixture(mut openai_fixture) or { panic(err) }
	defer {
		openai_server.stop()
		openai_thread.wait()
	}
	mut anthropic_server, anthropic_thread := start_routed_anthropic_fixture(mut anthropic_fixture) or { panic(err) }
	defer {
		anthropic_server.stop()
		anthropic_thread.wait()
	}

	mut store := open_store(os.join_path(root, 'data', 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	plugin_dir := os.join_path(root, 'plugins')
	os.mkdir_all(plugin_dir) or { panic(err) }
	mut app := new_app(store, plugin_dir)
	defer { app.close() }
	mut settings := app.model_settings
	settings.update(ModelSettingsInput{
		provider: 'openai-compatible'
		model:    'parent-fixture'
		base_url: 'http://${openai_server.addr}/v1'
		api_key:  'fixture-only-openai-key'
	}) or { panic(err) }
	settings.update(ModelSettingsInput{
		provider: 'anthropic'
		model:    'anthropic-child-fixture'
		base_url: 'http://${anthropic_server.addr}/v1'
		api_key:  'fixture-only-anthropic-key'
	}) or { panic(err) }
	parent := store.create_session(SessionInput{
		title:     'HTTP cross-provider acceptance'
		directory: workspace
	}) or { panic(err) }

	mut port_listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	port := port_listener.addr() or { panic(err) }.port() or { panic(err) }
	port_listener.close() or { panic(err) }
	mut api_server_app := &SubagentHTTPServer{
		app:          app
		port:         port
		server_ready: chan &veb.Server{cap: 1}
	}
	api_server_thread := spawn run_subagent_http_test_server(mut api_server_app)
	api_server := <-api_server_app.server_ready
	api_server.wait_till_running() or { panic(err) }
	defer {
		api_server.shutdown(timeout: 5 * time.second) or {}
		api_server_thread.wait()
	}
	// On assertion failure, free provider handlers before later app/server
	// cleanup waits for their workers. The helper guarantees one buffered send
	// per fixture even when normal scenario flow already released a handler.
	defer {
		release_routed_provider_fixture(mut openai_fixture)
		release_routed_provider_fixture(mut anthropic_fixture)
	}
	base_url := 'http://127.0.0.1:${port}/v1/sessions/${parent.id}/subagents'
	started_at := time.sys_mono_now()
	openai_run := create_http_subagent(base_url, 'openai-child', 'explorer', 'openai-compatible',
		'openai-child-fixture')
	anthropic_run := create_http_subagent(base_url, 'anthropic-child', 'reviewer', 'anthropic',
		'anthropic-child-fixture')
	assert openai_run.status in ['queued', 'running']
	assert anthropic_run.status in ['queued', 'running']
	assert openai_run.target_provider == 'openai-compatible'
	assert openai_run.target_model == 'openai-child-fixture'
	assert anthropic_run.target_provider == 'anthropic'
	assert anthropic_run.target_model == 'anthropic-child-fixture'

	// Both independent provider servers must receive their native adapter
	// requests while each remains blocked. This proves real overlap at the HTTP
	// transport boundary rather than concurrent request metadata alone.
	select {
		_ := <-openai_fixture.started {
		}
		10 * time.second {
			panic('OpenAI-compatible child did not reach its loopback provider')
		}
	}
	select {
		_ := <-anthropic_fixture.started {
		}
		10 * time.second {
			panic('Anthropic child did not reach its loopback provider while OpenAI was blocked')
		}
	}
	assert time.sys_mono_now() - started_at < u64(10 * time.second)
	assert openai_fixture.path == '/v1/chat/completions'
	assert openai_fixture.model == 'openai-child-fixture'
	assert openai_fixture.body.contains('"model":"openai-child-fixture"')
	assert anthropic_fixture.path == '/v1/messages'
	assert anthropic_fixture.model == 'anthropic-child-fixture'
	assert anthropic_fixture.body.contains('"model":"anthropic-child-fixture"')

	// The first scenario proves one provider can finish without waiting on its
	// sibling. The second releases both providers only after both have reached
	// their barriers, then independently observes two successful results.
	release_routed_provider_fixture(mut anthropic_fixture)
	anthropic_fixture.block = false
	if cancel_openai {
		anthropic_done := wait_for_http_subagent(base_url, anthropic_run.id)
		assert anthropic_done.status == 'completed'
		assert anthropic_done.provider == 'anthropic'
		assert anthropic_done.model == 'anthropic-child-fixture'
		assert anthropic_done.result.contains('ANTHROPIC-CHILD-RESULT')
		assert anthropic_done.input_tokens == 9
		assert anthropic_done.output_tokens == 3

		cancel_response := http.fetch(
			url:           '${base_url}/${openai_run.id}/cancel'
			method:        .post
			read_timeout:  5 * time.second
			write_timeout: 5 * time.second
		) or { panic(err) }
		assert cancel_response.status_code == 200
		cancelled_view := json2.decode[SubagentRun](cancel_response.body) or { panic(err) }
		assert cancelled_view.cancel_requested || cancelled_view.status in ['cancelled', 'uncertain']
		release_routed_provider_fixture(mut openai_fixture)
		openai_fixture.block = false
		openai_done := wait_for_http_subagent(base_url, openai_run.id)
		assert openai_done.status in ['cancelled', 'uncertain']
		assert openai_done.provider == 'openai-compatible'
		assert openai_done.model == 'openai-child-fixture'
	} else {
		release_routed_provider_fixture(mut openai_fixture)
		openai_fixture.block = false
		openai_done := wait_for_http_subagent(base_url, openai_run.id)
		anthropic_done := wait_for_http_subagent(base_url, anthropic_run.id)
		assert openai_done.status == 'completed'
		assert openai_done.provider == 'openai-compatible'
		assert openai_done.model == 'openai-child-fixture'
		assert openai_done.result.contains('OPENAI-CHILD-RESULT')
		assert openai_done.input_tokens == 11
		assert openai_done.output_tokens == 4
		assert anthropic_done.status == 'completed'
		assert anthropic_done.provider == 'anthropic'
		assert anthropic_done.model == 'anthropic-child-fixture'
		assert anthropic_done.result.contains('ANTHROPIC-CHILD-RESULT')
		assert anthropic_done.input_tokens == 9
		assert anthropic_done.output_tokens == 3
	}
	assert openai_fixture.request_count == 1
	assert anthropic_fixture.request_count == 1

	list_response := http.get(base_url) or { panic(err) }
	assert list_response.status_code == 200
	listed := json2.decode[[]SubagentRun](list_response.body) or { panic(err) }
	assert listed.any(it.id == openai_run.id && it.provider == 'openai-compatible'
		&& it.model == 'openai-child-fixture')
	if cancel_openai {
		assert listed.any(it.id == anthropic_run.id && it.provider == 'anthropic'
			&& it.model == 'anthropic-child-fixture' && it.status == 'completed')
	} else {
		assert listed.any(it.id == openai_run.id && it.provider == 'openai-compatible'
			&& it.model == 'openai-child-fixture' && it.status == 'completed'
			&& it.result.contains('OPENAI-CHILD-RESULT') && it.input_tokens == 11
			&& it.output_tokens == 4)
		assert listed.any(it.id == anthropic_run.id && it.provider == 'anthropic'
			&& it.model == 'anthropic-child-fixture' && it.status == 'completed'
			&& it.result.contains('ANTHROPIC-CHILD-RESULT') && it.input_tokens == 9
			&& it.output_tokens == 3)
	}
}
