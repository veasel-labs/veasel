module main

import os
import json2
import context as vcontext
import sync
import uuid
import time
import net.http

fn test_openai_responses_history_replays_encrypted_reasoning_and_tool_outputs() {
	messages := [
		ChatMessage{ role: 'system', content: 'system instruction' },
		ChatMessage{ role: 'user', content: 'inspect this repository' },
		ChatMessage{
			role:             'assistant'
			content:          'I will inspect the repository.'
			provider_context: ['{"type":"reasoning","id":"rs_fixture","summary":[],"encrypted_content":"opaque"}']
			tool_calls:       [ProviderToolCall{
				id:               'call_fixture'
				provider_call_id: 'fc_fixture'
				function:         ProviderFunctionCall{
					name:      'workspace_search'
					arguments: '{"query":"needle"}'
				}
			}]
		},
		ChatMessage{
			role:         'tool'
			tool_call_id: 'call_fixture'
			content:      '{"matches":[]}'
		},
	]
	input := openai_responses_input(messages) or { panic(err) }
	assert !json2.encode[ChatMessage](messages[2]).contains('opaque')
	assert input.len == 6
	assert input[2].as_map()['type'] or { panic('reasoning item type missing') } == json2.Any('reasoning')
	assert input[2].as_map()['encrypted_content'] or { panic('reasoning ciphertext missing') } == json2.Any('opaque')
	assert input[3].as_map()['phase'] or { panic('assistant phase missing') } == json2.Any('commentary')
	assert input[4].as_map()['call_id'] or { panic('function call ID missing') } == json2.Any('call_fixture')
	assert input[5].as_map()['type'] or { panic('tool output type missing') } == json2.Any('function_call_output')
	assert input[5].as_map()['call_id'] or { panic('tool output call ID missing') } == json2.Any('call_fixture')
	assert input[5].as_map()['output'] or { panic('tool output missing') } == json2.Any('{"matches":[]}')
}

fn test_openai_responses_history_rejects_overlong_function_call_ids() {
	messages := [ChatMessage{
		role:         'tool'
		tool_call_id: 'x'.repeat(65)
		content:      '{}'
	}]
	openai_responses_input(messages) or {
		assert err.msg() == 'provider tool call ID is invalid for Responses API'
		return
	}
	assert false
}

fn test_openai_responses_failures_read_top_level_and_response_errors() {
	top_level := json2.decode[OpenAIResponsesEvent]('{"type":"error","error":{"message":"request rejected"}}') or {
		panic(err)
	}
	assert openai_responses_failure_message(top_level) == 'request rejected'

	failed := json2.decode[OpenAIResponsesEvent]('{"type":"response.failed","response":{"error":{"message":"model unavailable"}}}') or {
		panic(err)
	}
	assert openai_responses_failure_message(failed) == 'model unavailable'

	empty := OpenAIResponsesEvent{}
	assert openai_responses_failure_message(empty) == 'provider response failed'
}

fn test_openai_responses_reasoning_is_limited_to_supported_models() {
	assert openai_responses_model_supports_reasoning('meta', 'muse-wonder-1.0')
	assert openai_responses_model_supports_reasoning('openai', 'gpt-5.1-codex')
	assert openai_responses_model_supports_reasoning('openai', 'o3')
	assert openai_responses_model_supports_reasoning('openai', 'o4-mini')
	assert openai_responses_model_supports_reasoning('openai', 'codex-mini-latest')
	assert !openai_responses_model_supports_reasoning('openai', 'gpt-4.1')
	assert !openai_responses_model_supports_reasoning('openai', 'gpt-4o')
	assert openai_responses_include('meta', 'muse-wonder-1.0') == ['reasoning.encrypted_content']
	assert openai_responses_include('openai', 'gpt-5.1-codex') == ['reasoning.encrypted_content']
	assert openai_responses_include('openai-responses', 'gpt-4.1') == []
	openai_responses_reasoning('openai', 'gpt-4.1') or { return }
	assert false
	codex_reasoning := openai_responses_reasoning('openai', 'gpt-5.1-codex') or {
		panic('Codex reasoning settings missing')
	}
	assert codex_reasoning.effort == 'high'
	assert codex_reasoning.summary == 'auto'
	legacy_payload := json2.decode[map[string]json2.Any](json2.encode(OpenAIResponsesRequest{
		model:     'gpt-4.1'
		include:   openai_responses_include('openai', 'gpt-4.1')
		reasoning: openai_responses_reasoning('openai', 'gpt-4.1')
	})) or { panic(err) }
	assert 'reasoning' !in legacy_payload
	assert 'include' !in legacy_payload
	assert 'max_output_tokens' !in legacy_payload
	provider_default_payload := json2.decode[map[string]json2.Any](json2.encode(OpenAIResponsesRequest{
		model:             'muse-wonder-1.0'
		max_output_tokens: none
	})) or { panic(err) }
	assert 'max_output_tokens' !in provider_default_payload
	bounded_payload := json2.decode[map[string]json2.Any](json2.encode(OpenAIResponsesRequest{
		model:             'muse-wonder-1.0'
		max_output_tokens: 8192
	})) or { panic(err) }
	encoded_budget := bounded_payload['max_output_tokens'] or { panic('max output token budget missing') }
	assert encoded_budget == json2.Any(8192)
	codex_payload := json2.decode[map[string]json2.Any](json2.encode(OpenAIResponsesRequest{
		model:     'gpt-5.1-codex'
		include:   openai_responses_include('openai', 'gpt-5.1-codex')
		reasoning: openai_responses_reasoning('openai', 'gpt-5.1-codex')
	})) or { panic(err) }
	assert 'reasoning' in codex_payload
	assert 'include' in codex_payload
}

fn test_serve_and_tui_help_are_available_without_starting_the_backend() {
	assert command_help('serve').starts_with('Usage: veasel serve\n')
	assert command_help('serve').contains('Start the local V backend only.')
	assert command_help('tui').starts_with('Usage: veasel tui\n')
	assert command_help('tui').contains('Start or reuse the local backend')
	assert command_help('run').len == 0
	assert command_help('mcp').starts_with('Usage: veasel mcp ')
	assert command_help('mcp').contains('Trust and per-call approval')
}

fn test_session_turn_semaphores_serialize_the_same_session() {
	store := open_store(':memory:') or { panic(err) }
	defer {
		store.close() or {}
	}
	plugin_directory := os.join_path(os.temp_dir(), 'veasel-test-plugins-${uuid.new_v4().str()}')
	os.mkdir_all(plugin_directory) or { panic(err) }
	defer { os.rmdir_all(plugin_directory) or {} }
	mut app := new_app(store, plugin_directory)
	defer {
		app.close()
	}
	mut first := app.session_turn_lock('session-a')
	mut second := app.session_turn_lock('session-a')
	assert first == second
	assert first.try_wait()
	assert !second.try_wait()
	first.post()
	assert second.try_wait()
	second.post()
	assert session_turn_lock_index('session-a') >= 0
	assert session_turn_lock_index('session-a') < session_turn_lock_stripes
}

fn test_turn_operation_can_be_cancelled_and_is_session_scoped() {
	store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	plugin_directory := os.join_path(os.temp_dir(), 'veasel-test-operations-${uuid.new_v4().str()}')
	os.mkdir_all(plugin_directory) or { panic(err) }
	defer { os.rmdir_all(plugin_directory) or {} }
	mut app := new_app(store, plugin_directory)
	defer { app.close() }
	operation_id := uuid.new_v4().str()
	actual_id, mut turn_ctx, cancel := app.begin_turn_operation('session-a', operation_id) or {
		panic(err)
	}
	assert actual_id == operation_id
	assert !app.cancel_turn_operation('session-b', operation_id)
	assert app.cancel_turn_operation('session-a', operation_id.to_upper())
	ctx_error := turn_ctx.err()
	assert ctx_error !is none
	assert ctx_error.msg().contains('canceled')
	app.finish_turn_operation(operation_id)
	assert !app.cancel_turn_operation('session-a', operation_id)
	cancel()
}

fn test_turn_cancellation_releases_a_queued_session_turn() {
	store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	plugin_directory := os.join_path(os.temp_dir(), 'veasel-test-queued-turn-${uuid.new_v4().str()}')
	os.mkdir_all(plugin_directory) or { panic(err) }
	defer { os.rmdir_all(plugin_directory) or {} }
	mut app := new_app(store, plugin_directory)
	defer { app.close() }
	mut slot := app.session_turn_lock('session-queued')
	slot.wait()
	mut background := vcontext.background()
	mut turn_ctx, cancel := vcontext.with_cancel(mut background)
	result := chan string{cap: 1}
	spawn fn (app &App, mut turn_ctx vcontext.Context, result chan string) {
		app.acquire_session_turn(mut turn_ctx, 'session-queued') or {
			result <- err.msg()
			return
		}
		mut acquired := app.session_turn_lock('session-queued')
		acquired.post()
		result <- 'acquired'
	}(app, mut turn_ctx, result)
	time.sleep(25 * time.millisecond)
	cancel()
	assert <-result == 'cancelled'
	slot.post()
}

fn test_provider_semaphore_enforces_its_configured_capacity() {
	mut slots := sync.new_semaphore_init(max_provider_concurrency)
	defer {
		slots.destroy()
	}
	for _ in 0 .. max_provider_concurrency {
		assert slots.try_wait()
	}
	assert !slots.try_wait()
	slots.post()
	assert slots.try_wait()
}

fn test_plugin_mcp_semaphore_caps_concurrent_plugin_turns() {
	store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	plugin_directory := os.join_path(os.temp_dir(), 'veasel-test-mcp-slots-${uuid.new_v4().str()}')
	os.mkdir_all(plugin_directory) or { panic(err) }
	defer { os.rmdir_all(plugin_directory) or {} }
	mut app := new_app(store, plugin_directory)
	defer { app.close() }
	for _ in 0 .. max_plugin_mcp_concurrency {
		assert app.try_plugin_mcp_slot()
	}
	assert !app.try_plugin_mcp_slot()
	mut slots := app.plugin_mcp_slots
	slots.post()
	assert app.try_plugin_mcp_slot()
}

fn test_session_mcp_trust_limit_allows_updates_but_rejects_an_extra_server() {
	mut active := []SessionPluginMCPServer{cap: max_session_plugin_mcp_servers}
	for index in 0 .. max_session_plugin_mcp_servers {
		active << SessionPluginMCPServer{
			plugin_name: 'plugin-${index}'
			server_name: 'server'
		}
	}
	assert session_can_trust_plugin_mcp_server(active, 'plugin-0', 'server')
	assert !session_can_trust_plugin_mcp_server(active, 'another-plugin', 'server')
}

fn test_shell_command_requires_review_and_is_marked_uncertain_after_restart() {
	root := os.join_path(os.temp_dir(), 'veasel-shell-store-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	db_path := os.join_path(root, 'veasel.sqlite3')
	mut store := open_store(db_path) or { panic(err) }
	session := store.create_session(SessionInput{ title: 'Shell approval', directory: root }) or { panic(err) }
	draft := prepare_shell_command(root, 'touch must-not-run', '.', 10) or { panic(err) }
	proposal := store.create_shell_command(session.id, draft) or { panic(err) }
	assert !os.exists(os.join_path(root, 'must-not-run'))
	_ := store.begin_shell_command(session.id, proposal.id) or {
		assert err.msg().contains('reviewed')
		ShellCommandSummary{}
	}
	reviewed := store.review_shell_command(session.id, proposal.id) or { panic(err) }
	assert reviewed.status == 'pending'
	running := store.begin_shell_command(session.id, proposal.id) or { panic(err) }
	assert running.status == 'running'
	store.close() or { panic(err) }
	mut recovered := open_store(db_path) or { panic(err) }
	defer { recovered.close() or {} }
	commands := recovered.shell_commands(session.id) or { panic(err) }
	assert commands.len == 1
	assert commands[0].status == 'uncertain'
	assert !os.exists(os.join_path(root, 'must-not-run'))
}

fn test_mcp_tool_call_requires_inspection_approval_and_recovers_without_replay() {
	root := os.join_path(os.temp_dir(), 'veasel-mcp-approval-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	db_path := os.join_path(root, 'veasel.sqlite3')
	mut store := open_store(db_path) or { panic(err) }
	session := store.create_session(SessionInput{ title: 'MCP approval', directory: root }) or {
		panic(err)
	}
	pending := store.create_plugin_mcp_tool_call(session.id, uuid.new_v4().str(), 'fixture', 'tools',
		'write_file', '{"path":"sentinel"}') or { panic(err) }
	assert pending.status == 'pending'
	assert pending.plugin_name == 'fixture'
	assert pending.server_name == 'tools'
	assert pending.tool_name == 'write_file'
	assert pending.arguments_json == '{"path":"sentinel"}'
	oversized_arguments := '{"value":"' + 'x'.repeat(max_plugin_mcp_tool_call_argument_bytes) + '"}'
	_ = store.create_plugin_mcp_tool_call(session.id, uuid.new_v4().str(), 'fixture', 'tools',
		'write_file', oversized_arguments) or {
		assert err.msg().contains('size limit')
		PluginMCPToolCallApproval{}
	}
	_ = store.create_plugin_mcp_tool_call(session.id, uuid.new_v4().str(), 'fixture', 'tools',
		'write_file', '[]') or {
		assert err.msg().contains('JSON object')
		PluginMCPToolCallApproval{}
	}
	store.approve_plugin_mcp_tool_call(session.id, pending.id) or {
		assert err.msg().contains('expected state')
	}
	reviewed := store.review_plugin_mcp_tool_call(session.id, pending.id) or { panic(err) }
	assert reviewed.reviewed_at.len > 0
	store.approve_plugin_mcp_tool_call(session.id, pending.id) or { panic(err) }
	store.begin_plugin_mcp_tool_call(session.id, pending.id) or { panic(err) }
	store.finish_plugin_mcp_tool_call(session.id, pending.id, 'completed') or { panic(err) }
	assert (store.get_plugin_mcp_tool_call(session.id, pending.id) or { panic(err) }).status == 'completed'
	approved := store.create_plugin_mcp_tool_call(session.id, uuid.new_v4().str(), 'fixture', 'tools',
		'write_file', '{"path":"approved"}') or { panic(err) }
	_ = store.review_plugin_mcp_tool_call(session.id, approved.id) or { panic(err) }
	store.approve_plugin_mcp_tool_call(session.id, approved.id) or { panic(err) }
	running := store.create_plugin_mcp_tool_call(session.id, uuid.new_v4().str(), 'fixture', 'tools',
		'write_file', '{"path":"running"}') or { panic(err) }
	_ = store.review_plugin_mcp_tool_call(session.id, running.id) or { panic(err) }
	store.approve_plugin_mcp_tool_call(session.id, running.id) or { panic(err) }
	store.begin_plugin_mcp_tool_call(session.id, running.id) or { panic(err) }
	unreviewed := store.create_plugin_mcp_tool_call(session.id, uuid.new_v4().str(), 'fixture', 'tools',
		'write_file', '{"path":"unreviewed"}') or { panic(err) }
	rejected := store.create_plugin_mcp_tool_call(session.id, uuid.new_v4().str(), 'fixture', 'tools',
		'write_file', '{"path":"rejected"}') or { panic(err) }
	store.reject_plugin_mcp_tool_call(session.id, rejected.id) or { panic(err) }
	store.close() or { panic(err) }
	mut recovered := open_store(db_path) or { panic(err) }
	defer { recovered.close() or {} }
	calls := recovered.plugin_mcp_tool_calls(session.id) or { panic(err) }
	assert calls.len == 5
	assert mcp_tool_call_status(calls, pending.id) == 'completed'
	assert mcp_tool_call_status(calls, approved.id) == 'cancelled'
	assert mcp_tool_call_status(calls, running.id) == 'uncertain'
	assert mcp_tool_call_status(calls, rejected.id) == 'rejected'
	assert mcp_tool_call_status(calls, unreviewed.id) == 'cancelled'
	assert mcp_tool_call_summary(calls, pending.id).arguments_bytes == pending.arguments_json.len
}

fn mcp_tool_call_status(calls []PluginMCPToolCallSummary, id string) string {
	for call in calls {
		if call.id == id {
			return call.status
		}
	}
	return ''
}

fn mcp_tool_call_summary(calls []PluginMCPToolCallSummary, id string) PluginMCPToolCallSummary {
	for call in calls {
		if call.id == id {
			return call
		}
	}
	return PluginMCPToolCallSummary{}
}

fn test_shell_command_rejects_workspace_escape_and_invalid_limits() {
	root := os.join_path(os.temp_dir(), 'veasel-shell-path-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	_ := prepare_shell_command(root, 'echo safe', '../', 5) or { return }
	assert false, 'parent traversal must be rejected'
}

fn test_shell_command_rejects_terminal_spoofing_controls() {
	root := os.join_path(os.temp_dir(), 'veasel-shell-control-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	_ := prepare_shell_command(root, 'echo safe\nrm -rf .', '.', 5) or { return }
	assert false, 'multiline commands must be rejected so the review text is unambiguous'
}

fn test_shell_command_rejects_unicode_line_separators() {
	root := os.join_path(os.temp_dir(), 'veasel-shell-separator-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	_ := prepare_shell_command(root, 'echo safe\u2028rm -rf .', '.', 5) or { return }
	assert false, 'Unicode line separators must not alter reviewed command rendering'
}

fn test_shell_command_rejects_zero_width_formatting_characters() {
	root := os.join_path(os.temp_dir(), 'veasel-shell-format-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	_ := prepare_shell_command(root, 'echo safe\u200B-hidden', '.', 5) or { return }
	assert false, 'invisible Unicode formatting characters must not alter reviewed command rendering'
}

fn test_shell_command_registry_rejects_work_after_shutdown_starts() {
	store := open_store(':memory:') or { panic(err) }
	mut app := new_app(store, os.temp_dir())
	assert app.begin_shell_operation()
	app.close_shell_operations()
	assert !app.begin_shell_operation()
	app.finish_shell_operation()
	app.wait_for_shell_operations()
	app.close()
	store.close() or { panic(err) }
}

fn test_workspace_edit_approval_is_durable_single_use_and_recovered_after_restart() {
	root := os.join_path(os.temp_dir(), 'veasel-edit-store-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	database := os.join_path(root, 'veasel.sqlite')
	workspace_file := os.join_path(root, 'existing.v')
	os.write_file(workspace_file, 'original\n') or { panic(err) }
	mut store := open_store(database) or { panic(err) }
	session := store.create_session(SessionInput{ title: 'Edit approval', directory: root }) or {
		panic(err)
	}
	draft := WorkspaceEditDraft{
		path:          'existing.v'
		expected_hash: workspace_content_hash('original\n')
		content:       'module fixture\n'
		diff:          '-original\n+module fixture\n'
		create_file:   false
	}
	proposal := store.create_workspace_edit(session.id, draft) or { panic(err) }
	assert proposal.status == 'pending'
	assert proposal.diff == '-original\n+module fixture\n'
	assert (store.workspace_edits(session.id) or { panic(err) }).len == 1
	assert workspace_edit_review_required(mut store, session.id, proposal.id)
	reviewed := store.review_workspace_edit(session.id, proposal.id) or { panic(err) }
	assert reviewed.status == 'pending'
	applying := store.begin_workspace_edit(session.id, proposal.id) or { panic(err) }
	assert applying.status == 'applying'
	assert workspace_edit_second_approval_rejected(mut store, session.id, proposal.id)
	store.close() or { panic(err) }
	os.rm(workspace_file) or { panic(err) }
	backup := os.join_path(root, '.veasel-edit-${proposal.id}.bak')
	os.write_file(backup, 'original\n') or { panic(err) }
	mut recovered_store := open_store(database) or { panic(err) }
	recovered := recovered_store.workspace_edits(session.id) or { panic(err) }
	assert recovered.len == 1
	assert recovered[0].status == 'interrupted'
	assert os.read_file(workspace_file) or { panic(err) } == 'original\n'
	assert !os.exists(backup)
	assert workspace_edit_second_approval_rejected(mut recovered_store, session.id, proposal.id)
	recovered_store.close() or { panic(err) }
	os.rm(workspace_file) or { panic(err) }
	os.write_file(backup, 'original\n') or { panic(err) }
	mut retried_store := open_store(database) or { panic(err) }
	defer { retried_store.close() or {} }
	assert os.read_file(workspace_file) or { panic(err) } == 'original\n'
	assert !os.exists(backup)
}

fn workspace_edit_review_required(mut store Store, session_id string, id string) bool {
	_ := store.begin_workspace_edit(session_id, id) or {
		return err.msg().contains('diff has not been reviewed')
	}
	return false
}

fn workspace_edit_second_approval_rejected(mut store Store, session_id string, id string) bool {
	_ := store.begin_workspace_edit(session_id, id) or { return err.msg().contains('not awaiting approval') }
	return false
}

fn test_app_rejects_provider_work_when_all_slots_are_busy() {
	store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	plugin_directory := os.join_path(os.temp_dir(), 'veasel-test-plugins-${uuid.new_v4().str()}')
	os.mkdir_all(plugin_directory) or { panic(err) }
	defer { os.rmdir_all(plugin_directory) or {} }
	mut app := new_app(store, plugin_directory)
	defer { app.close() }
	mut slots := app.provider_slots
	for _ in 0 .. max_provider_concurrency {
		assert slots.try_wait()
	}
	assert !app.try_provider_slot()
	slots.post()
	assert app.try_provider_slot()
	slots.post()
}

fn test_tui_backend_output_goes_to_the_server_log() {
	$if windows {
		return
	}
	root := os.join_path(os.temp_dir(), 'veasel-server-log-${uuid.new_v4().str()}')
	defer { os.rmdir_all(root) or {} }
	log_path := server_log_path(root)
	assert log_path == os.join_path(root, 'logs', 'server.log')
	mut process := os.new_process('/bin/sh')
	process.set_args(['-c', 'echo server-stdout; echo server-stderr >&2'])
	spawn_backend_server(mut process, log_path) or { panic(err) }
	process.wait()
	process.close()
	log := os.read_file(log_path) or { panic(err) }
	assert log.contains('server-stdout')
	assert log.contains('server-stderr')
	// The CLI's own descriptors must be restored to their original targets.
	assert os.fd_dup2(1, 1) == 1
	assert os.fd_dup2(2, 2) == 2
}

struct BackendHealthFixture {}

fn (mut _ BackendHealthFixture) handle(request http.Request) http.Response {
	mut response := http.Response{}
	if request.url == '/v1/health' {
		response.header.set(.content_type, 'application/json')
		response.body = '{"healthy":true}'
		return response
	}
	response.set_status(.not_found)
	return response
}

fn test_backend_health_probe_and_ensure_reuses_healthy_listener() {
	assert !backend_is_healthy(1)
	mut fixture := &BackendHealthFixture{}
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
		panic(err)
	}
	defer {
		server.stop()
		server_thread.wait()
	}
	host_port := server.addr.all_after_last(':')
	port := host_port.int()
	assert port > 0
	assert backend_is_healthy(port)
	// Healthy reuse must not spawn; ensure_backend returns immediately.
	ensure_backend(port, '') or { panic(err) }
	assert backend_is_healthy(port)
}

fn test_tui_directory_is_resolved_next_to_the_executable() {
	root := os.join_path(os.temp_dir(), 'veasel-bundle-${uuid.new_v4().str()}')
	defer { os.rmdir_all(root) or {} }
	tui_dir := os.join_path(root, 'tui')
	executable := os.join_path(root, 'veasel')
	os.mkdir_all(tui_dir) or { panic(err) }
	os.write_file(os.join_path(tui_dir, 'package.json'), '{"name":"veasel-tui"}') or {
		panic(err)
	}
	os.write_file(executable, 'binary fixture') or { panic(err) }

	assert tui_directory_for_executable(executable) == os.real_path(tui_dir)
}

fn test_tui_standalone_executable_is_resolved_next_to_the_backend() {
	root := os.join_path(os.temp_dir(), 'veasel-bundle-${uuid.new_v4().str()}')
	defer { os.rmdir_all(root) or {} }
	executable := os.join_path(root, $if windows { 'veasel.exe' } $else { 'veasel' })
	os.mkdir_all(root) or { panic(err) }
	os.write_file(executable, 'binary fixture') or { panic(err) }
	name := $if windows { 'veasel-tui.exe' } $else { 'veasel-tui' }

	assert tui_executable_for_executable(executable) == os.join_path(os.real_path(root), name)
}

fn test_session_store_persists_session_and_creation_event() {
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	created := store.create_session(SessionInput{
		title:     'Improve parsing'
		directory: '/tmp/fixture'
	}) or { panic(err) }
	assert created.id.len == 36
	assert created.title == 'Improve parsing'
	assert created.directory == '/tmp/fixture'
	assert store.get_session(created.id) or { panic(err) } == created
	listed := store.list_sessions() or { panic(err) }
	assert listed.len == 1
	assert listed[0].id == created.id
	events := store.events_after(0) or { panic(err) }
	assert events.len == 1
	assert events[0].type == 'session.created'
	assert events[0].session_id == created.id
	assert events[0].id > 0
}

fn test_session_store_event_cursor_replays_only_newer_events() {
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	first := store.create_session(SessionInput{ title: 'First', directory: '/tmp/a' }) or {
		panic(err)
	}
	_ := store.create_session(SessionInput{ title: 'Second', directory: '/tmp/b' }) or {
		panic(err)
	}
	first_events := store.events_after(0) or { panic(err) }
	assert first_events.len == 2
	next_events := store.events_after(first_events[0].id) or { panic(err) }
	assert next_events.len == 1
	assert next_events[0].session_id != first.id
}

fn test_assistant_delta_events_persist_operation_and_text_for_replay() {
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{ title: 'Streaming', directory: '/tmp/streaming' }) or {
		panic(err)
	}
	operation_id := '123e4567-e89b-42d3-a456-426614174000'
	store.record_assistant_delta(session.id, operation_id, 'hello ') or { panic(err) }
	store.record_assistant_delta(session.id, operation_id, 'world') or { panic(err) }
	events := store.events_after(0) or { panic(err) }
	assert events.len == 3
	assert events[1].type == 'assistant.delta'
	assert events[1].session_id == session.id
	assert events[1].data.operation_id == operation_id
	assert events[1].data.delta == 'hello '
	assert events[2].data.delta == 'world'
	mut nul_rejected := false
	store.record_assistant_delta(session.id, operation_id, 'bad\0delta') or {
		nul_rejected = err.msg() == 'invalid streamed assistant delta'
	}
	assert nul_rejected
}

fn test_events_after_pages_at_event_stream_limit() {
	mut store := open_store(':memory:') or { panic(err) }
	defer {
		store.close() or {}
	}
	session := store.create_session(SessionInput{
		title:     'Event page size'
		directory: '/tmp/event-page-size'
	}) or { panic(err) }
	operation_id := '323e4567-e89b-42d3-a456-426614174002'
	for i in 0 .. max_event_stream_page_size {
		store.record_assistant_delta(session.id, operation_id, 'd${i}') or { panic(err) }
	}
	first_page := store.events_after(0) or { panic(err) }
	assert first_page.len == max_event_stream_page_size
	assert first_page[0].type == 'session.created'
	assert first_page[first_page.len - 1].type == 'assistant.delta'
	next_page := store.events_after(first_page[first_page.len - 1].id) or { panic(err) }
	assert next_page.len == 1
	assert next_page[0].data.delta == 'd${max_event_stream_page_size - 1}'
}

fn test_parse_sse_last_event_id_is_digit_only() {
	assert parse_sse_last_event_id('0')! == 0
	assert parse_sse_last_event_id('42')! == 42
	for invalid in ['', '+1', '-1', ' 1', '1 ', '1a', '01', '1.0', '0x10'] {
		mut rejected := false
		_ := parse_sse_last_event_id(invalid) or {
			rejected = err.msg() == 'Last-Event-ID must be a non-negative integer'
			0
		}
		assert rejected
	}
}

fn test_session_events_prune_to_retention_limit_during_streaming() {
	mut store := open_store(':memory:') or { panic(err) }
	defer {
		store.close() or {}
	}
	store.session_events_retention_limit = 4
	session := store.create_session(SessionInput{
		title:     'Event retention'
		directory: '/tmp/event-retention'
	}) or { panic(err) }
	operation_id := '223e4567-e89b-42d3-a456-426614174001'
	// session.created already consumed one slot.
	store.record_assistant_delta(session.id, operation_id, 'one') or { panic(err) }
	store.record_assistant_delta(session.id, operation_id, 'two') or { panic(err) }
	store.record_assistant_delta(session.id, operation_id, 'three') or { panic(err) }
	store.record_assistant_delta(session.id, operation_id, 'four') or { panic(err) }
	events := store.events_after(0) or { panic(err) }
	assert events.len == 4
	assert events[0].type == 'assistant.delta'
	assert events[0].data.delta == 'one'
	assert events[3].data.delta == 'four'
}

fn test_session_events_prune_to_retention_limit_after_exchange() {
	mut store := open_store(':memory:') or { panic(err) }
	defer {
		store.close() or {}
	}
	store.session_events_retention_limit = 3
	session := store.create_session(SessionInput{
		title:     'Exchange retention'
		directory: '/tmp/exchange-retention'
	}) or { panic(err) }
	_ = store.append_exchange(session.id, '', 'hello', 'world', '', '', '', ProviderUsage{}) or {
		panic(err)
	}
	_ = store.append_exchange(session.id, '', 'again', 'reply', '', '', '', ProviderUsage{}) or {
		panic(err)
	}
	events := store.events_after(0) or { panic(err) }
	assert events.len == 3
	assert events.filter(it.type == 'message.created').len == 3
}

struct ProviderSSETestState {
mut:
	messages []string
}

fn test_provider_sse_decoder_handles_split_crlf_and_multiline_data() {
	mut state := &ProviderSSETestState{}
	callback := fn [mut state] (data string) ! {
		state.messages << data
	}
	mut decoder := ProviderSSEDecoder{
		on_data: callback
	}
	decoder.feed('event: message\r\ndata: first\r'.bytes()) or { panic(err) }
	decoder.feed('\n\r\ndata: second\ndata: third\n\n'.bytes()) or { panic(err) }
	decoder.feed('data: fourth\rdata: fifth\r\r'.bytes()) or { panic(err) }
	decoder.finish() or { panic(err) }
	assert state.messages == ['first', 'second\nthird', 'fourth\nfifth']
}

fn test_provider_sse_decoder_ignores_non_data_fields_and_flushes_final_frame() {
	mut state := &ProviderSSETestState{}
	callback := fn [mut state] (data string) ! {
		state.messages << data
	}
	mut decoder := ProviderSSEDecoder{
		on_data: callback
	}
	decoder.feed(': comment\nid: 4\nretry: 1000\ndata: [DONE]'.bytes()) or { panic(err) }
	decoder.finish() or { panic(err) }
	assert state.messages == ['[DONE]']
}

fn test_provider_sse_decoder_rejects_oversized_unterminated_frames() {
	mut decoder := ProviderSSEDecoder{
		on_data: fn (_ string) ! {}
	}
	too_large := 'x'.repeat(max_provider_response_bytes + 1)
	decoder.feed(too_large.bytes()) or {
		assert err.msg() == 'stream frame size limit exceeded'
		return
	}
	assert false, 'expected oversized stream frame to fail'
}

fn test_provider_sse_decoder_rejects_nul_bytes() {
	mut decoder := ProviderSSEDecoder{
		on_data: fn (_ string) ! {
			assert false, 'NUL chunk must not deliver data'
		}
	}
	decoder.feed('data: before\0after\n\n'.bytes()) or {
		assert err.msg() == 'provider SSE chunk contained a NUL byte'
		return
	}
	assert false, 'expected NUL provider SSE chunk to fail'
}

fn test_provider_sse_progress_aborts_on_cancel_before_2xx_decode() {
	mut background := vcontext.background()
	mut turn_ctx, cancel := vcontext.with_cancel(mut background)
	cancel()
	mut stream_state := &ProviderSSERequestState{
		decoder: ProviderSSEDecoder{
			on_data: fn (_ string) ! {
				assert false, 'cancelled progress must not decode SSE'
			}
		}
	}
	provider_sse_handle_progress(mut stream_state, mut turn_ctx, 'data: hi\n\n'.bytes(), 0) or {
		assert err.msg() == 'cancelled'
		assert stream_state.bytes == 'data: hi\n\n'.len
		return
	}
	assert false, 'expected cancelled turn to abort SSE progress'
}

fn test_provider_sse_progress_skips_non_2xx_body_without_decode() {
	mut background := vcontext.background()
	mut turn_ctx, _ := vcontext.with_cancel(mut background)
	mut state := &ProviderSSETestState{}
	mut stream_state := &ProviderSSERequestState{
		decoder: ProviderSSEDecoder{
			on_data: fn [mut state] (data string) ! {
				state.messages << data
			}
		}
	}
	provider_sse_handle_progress(mut stream_state, mut turn_ctx, 'error-body'.bytes(), 401)!
	assert state.messages.len == 0
	assert stream_state.bytes == 'error-body'.len
}

fn test_session_plugin_skills_persist_and_emit_only_state_changes() {
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{ title: 'Skill session', directory: '/tmp/skills' }) or {
		panic(err)
	}
	store.set_session_plugin_skill(session.id, 'review-tools', 'review', true) or { panic(err) }
	store.set_session_plugin_skill(session.id, 'review-tools', 'review', true) or { panic(err) }
	assert store.session_plugin_skills(session.id) or { panic(err) } == [SessionPluginSkill{
		plugin_name: 'review-tools'
		skill_name:  'review'
	}]
	events := store.events_after(0) or { panic(err) }
	assert events.len == 2
	assert events[1].type == 'session.skill_enabled'
	store.set_session_plugin_skill(session.id, 'review-tools', 'review', false) or { panic(err) }
	assert (store.session_plugin_skills(session.id) or { panic(err) }).len == 0
	updated_events := store.events_after(0) or { panic(err) }
	assert updated_events.len == 3
	assert updated_events[2].type == 'session.skill_disabled'
}

fn test_session_skill_invoke_queues_and_clears_on_take() {
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{ title: 'Invoke session', directory: '/tmp/invoke' }) or {
		panic(err)
	}
	pending := store.enqueue_session_skill_invoke(session.id, 'agents', 'review') or { panic(err) }
	assert pending == [SessionPluginSkill{
		plugin_name: 'agents'
		skill_name:  'review'
	}]
	events := store.events_after(0) or { panic(err) }
	assert events.any(it.type == 'session.skill_invoked')
	taken := store.take_session_skill_invokes(session.id) or { panic(err) }
	assert taken == pending
	assert (store.take_session_skill_invokes(session.id) or { panic(err) }).len == 0
	for index in 0 .. max_session_skill_invokes {
		store.enqueue_session_skill_invoke(session.id, 'agents', 'skill-${index}') or { panic(err) }
	}
	_ = store.enqueue_session_skill_invoke(session.id, 'agents', 'overflow') or {
		assert err.msg().contains('at most')
		return
	}
	panic('expected overflow enqueue to fail')
}

fn test_session_plugin_mcp_trust_persists_and_emits_only_state_changes() {
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{ title: 'MCP session', directory: '/tmp/mcp' }) or {
		panic(err)
	}
	store.set_session_plugin_mcp_server(session.id, 'local-tools', 'workspace', true) or {
		panic(err)
	}
	store.set_session_plugin_mcp_server(session.id, 'local-tools', 'workspace', true) or {
		panic(err)
	}
	assert store.session_plugin_mcp_servers(session.id) or { panic(err) } == [SessionPluginMCPServer{
		plugin_name: 'local-tools'
		server_name: 'workspace'
	}]
	events := store.events_after(0) or { panic(err) }
	assert events.len == 2
	assert events[1].type == 'session.mcp_server_trusted'
	store.set_session_plugin_mcp_server(session.id, 'local-tools', 'workspace', false) or {
		panic(err)
	}
	assert (store.session_plugin_mcp_servers(session.id) or { panic(err) }).len == 0
	updated_events := store.events_after(0) or { panic(err) }
	assert updated_events.len == 3
	assert updated_events[2].type == 'session.mcp_server_untrusted'
}

fn test_provider_tool_parameters_preserve_nested_mcp_json_schema() {
	schema := '{"type":"object","properties":{"files":{"type":"array","items":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},"required":["files"],"additionalProperties":false}'
	tool := AgentToolDefinition{
		name:           'mcp_review_list'
		description:    'List review files.'
		raw_parameters: schema
	}
	openai_payload := json2.encode[OpenAIRequest](OpenAIRequest{
		model: 'test'
		tools: [OpenAITool{
			function: OpenAIFunction{
				name:        tool.name
				description: tool.description
				parameters:  provider_tool_parameters(tool)
			}
		}]
	})
	assert_provider_schema_shape(openai_payload, 'openai')
	anthropic_payload := json2.encode[AnthropicRequest](AnthropicRequest{
		tools: [AnthropicTool{
			name:         tool.name
			description:  tool.description
			input_schema: provider_tool_parameters(tool)
		}]
	})
	assert_provider_schema_shape(anthropic_payload, 'anthropic')
	gemini_payload := json2.encode[GeminiRequest](GeminiRequest{
		tools: [GeminiToolGroup{
			function_declarations: [GeminiFunctionDeclaration{
				name:        tool.name
				description: tool.description
				parameters:  tool_parameters_json(tool)
			}]
		}]
	})
	assert_provider_schema_shape(gemini_payload, 'gemini')
}

fn assert_provider_schema_shape(payload string, provider string) {
	root := json2.decode[map[string]json2.Any](payload) or { panic(err) }
	mut schema := json2.Any{}
	if provider == 'openai' {
		tools := provider_json_array(root['tools'] or { panic('missing tools') })
		tool := provider_json_object(tools[0])
		function := provider_json_object(tool['function'] or { panic('missing function') })
		schema = function['parameters'] or { panic('missing parameters') }
	} else if provider == 'anthropic' {
		tools := provider_json_array(root['tools'] or { panic('missing tools') })
		tool := provider_json_object(tools[0])
		schema = tool['input_schema'] or { panic('missing input schema') }
	} else {
		groups := provider_json_array(root['tools'] or { panic('missing tools') })
		group := provider_json_object(groups[0])
		declarations := provider_json_array(group['functionDeclarations'] or {
			panic('missing function declarations')
		})
		declaration := provider_json_object(declarations[0])
		schema = declaration['parameters'] or { panic('missing parameters') }
	}
	root_schema := provider_json_object(schema)
	assert root_schema['type'] or { panic('missing root type') } == json2.Any('object')
	properties := provider_json_object(root_schema['properties'] or { panic('missing properties') })
	files := provider_json_object(properties['files'] or { panic('missing files') })
	assert files['type'] or { panic('missing files type') } == json2.Any('array')
	items := provider_json_object(files['items'] or { panic('missing items') })
	assert items['type'] or { panic('missing item type') } == json2.Any('object')
	item_properties := provider_json_object(items['properties'] or { panic('missing item properties') })
	path := provider_json_object(item_properties['path'] or { panic('missing path property') })
	assert path['type'] or { panic('missing path type') } == json2.Any('string')
	required := provider_json_array(items['required'] or { panic('missing required') })
	assert required == [json2.Any('path')]
}

fn provider_json_object(value json2.Any) map[string]json2.Any {
	if value !is map[string]json2.Any {
		panic('expected JSON object')
	}
	return value as map[string]json2.Any
}

fn provider_json_array(value json2.Any) []json2.Any {
	if value !is []json2.Any {
		panic('expected JSON array')
	}
	return value as []json2.Any
}

fn test_plugin_mcp_provider_name_is_bounded_and_namespaced() {
	first := plugin_mcp_provider_name('review-tools', 'local.server', 'read-files')
	second := plugin_mcp_provider_name('review-tools', 'local.server', 'write-files')
	assert first.starts_with('mcp_')
	assert first.len <= 64
	assert first != second
	for character in first {
		assert character.is_alnum() || character in [`_`, `-`]
	}
}

fn test_session_title_is_not_interpreted_as_sql() {
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	title := "fix'; DROP TABLE sessions; --"
	session := store.create_session(SessionInput{ title: title, directory: '/tmp/safe' }) or {
		panic(err)
	}
	assert session.title == title
	assert store.list_sessions() or { panic(err) }.len == 1
}

fn test_session_and_event_write_roll_back_together() {
	mut store := open_store(':memory:') or { panic(err) }
	defer {
		store.close() or {}
	}
	store.db.exec("CREATE TRIGGER reject_session_events BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT, 'test failure'); END") or {
		panic(err)
	}
	mut failed := false
	mut failure_message := ''
	_ := store.create_session(SessionInput{ title: 'Atomic', directory: '/tmp/test' }) or {
		failed = true
		failure_message = err.msg()
		Session{}
	}
	assert failed, 'session creation should fail when event persistence fails'
	assert failure_message == 'unable to write session event'
	assert (store.list_sessions() or { panic(err) }).len == 0
	assert (store.events_after(0) or { panic(err) }).len == 0
	store.db.exec('DROP TRIGGER reject_session_events') or { panic(err) }
	recovered := store.create_session(SessionInput{ title: 'Recovered', directory: '/tmp/test' }) or {
		panic(err)
	}
	assert recovered.title == 'Recovered'
}

fn test_chat_exchange_is_persisted_atomically_and_replayed() {
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{ title: 'Chat', directory: '/tmp/chat' }) or {
		panic(err)
	}
	exchange := store.append_exchange(session.id, '', 'What is this?', 'A test reply.', '', '', '',
		ProviderUsage{}) or {
		panic(err)
	}
	assert exchange.len == 2
	assert exchange[0].role == 'user'
	assert exchange[0].content == 'What is this?'
	assert exchange[1].role == 'assistant'
	assert exchange[1].content == 'A test reply.'
	replayed := store.messages_for_session(session.id, 10) or { panic(err) }
	assert replayed == exchange
	events := store.events_after(0) or { panic(err) }
	assert events.len == 3
	assert events[1].type == 'message.created'
	assert events[2].type == 'message.created'
}

fn test_chat_history_pages_use_an_exclusive_message_cursor() {
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{ title: 'Paged chat', directory: '/tmp/chat' }) or {
		panic(err)
	}
	for index in 0 .. 3 {
		_ = store.append_exchange(session.id, '', 'Question ${index}', 'Answer ${index}', '', '', '',
			ProviderUsage{}) or {
			panic(err)
		}
	}
	latest := store.messages_page_for_session(session.id, 2, 0) or { panic(err) }
	assert latest.len == 2
	assert latest[0].content == 'Question 2'
	assert latest[1].content == 'Answer 2'
	previous := store.messages_page_for_session(session.id, 2, latest[0].id) or { panic(err) }
	assert previous.len == 2
	assert previous[0].content == 'Question 1'
	assert previous[1].content == 'Answer 1'
	mut invalid_cursor_rejected := false
	_ = store.messages_page_for_session(session.id, 2, -1) or {
		invalid_cursor_rejected = true
		[]ChatTurn{}
	}
	assert invalid_cursor_rejected
}

fn test_session_title_rejects_control_characters() {
	assert valid_session_title('Review branch')
	assert valid_session_title('a'.repeat(200))
	assert !valid_session_title('')
	assert !valid_session_title('a'.repeat(201))
	assert !valid_session_title('bad\ntitle')
	assert !valid_session_title('bad\rtitle')
	assert !valid_session_title('bad\0title')
	assert !valid_session_title('bad\ttitle')
	assert !valid_session_title('bad\x1btitle')
	mut nul_rejected := false
	_ = canonical_workspace_root('/tmp/workspace\0escape') or {
		nul_rejected = true
		''
	}
	assert nul_rejected
}

fn test_prefer_header_includes_respond_async_is_case_insensitive() {
	assert prefer_header_includes_respond_async('respond-async')
	assert prefer_header_includes_respond_async('Respond-Async')
	assert prefer_header_includes_respond_async(' wait=10, RESPOND-ASYNC;foo=bar ')
	assert prefer_header_includes_respond_async('respond-async; wait=5, handling=strict')
	assert !prefer_header_includes_respond_async('')
	assert !prefer_header_includes_respond_async('wait=10')
	assert !prefer_header_includes_respond_async('respond-async-later')
	assert !prefer_header_includes_respond_async('x-respond-async')
}

fn test_async_session_turn_completion_event_commits_with_exchange() {
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{ title: 'Async chat', directory: '/tmp/chat' }) or {
		panic(err)
	}
	operation_id := 'b1f21cb9-6f34-43d6-b924-7e8b71d9b307'
	_ = store.append_exchange(session.id, operation_id, 'Review this change', 'Looks good.',
		'openai-compatible', 'fixture-model', '', ProviderUsage{}) or { panic(err) }
	events := store.events_after(0) or { panic(err) }
	completion := events[events.len - 1]
	assert completion.type == 'session.turn_completed'
	assert completion.session_id == session.id
	assert completion.data.operation_id == operation_id
	assert completion.data.status == 'completed'
	assert completion.data.provider == 'openai-compatible'
	assert completion.data.model == 'fixture-model'
	assert !completion.data.usage_reported
	assert completion.data.input_tokens == 0
	assert completion.data.output_tokens == 0
}

fn test_session_operation_persists_provider_reported_token_usage() {
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{ title: 'Usage chat', directory: '/tmp/usage' }) or {
		panic(err)
	}
	operation_id := 'c2a31db0-7e45-44e7-8035-8f9c82e0c418'
	_ = store.create_session_operation(session.id, operation_id) or { panic(err) }
	_ = store.append_exchange(session.id, operation_id, 'Count tokens', 'Done.', 'openai-compatible',
		'fixture-model', '', ProviderUsage{
			input_tokens:          1200
			output_tokens:         340
			cache_read_tokens:     900
			cache_creation_tokens: 0
			cache_reported:        true
			reported:              true
		}) or { panic(err) }
	operation := store.get_session_operation(session.id, operation_id) or { panic(err) }
	assert operation.status == 'completed'
	assert operation.usage_reported
	assert operation.input_tokens == 1200
	assert operation.output_tokens == 340
	assert operation.cache_reported
	assert operation.cache_read_tokens == 900
	assert operation.cache_creation_tokens == 0
	events := store.events_after(0) or { panic(err) }
	completion := events.filter(it.type == 'session.turn_completed')[0]
	assert completion.data.usage_reported
	assert completion.data.input_tokens == 1200
	assert completion.data.output_tokens == 340
	assert completion.data.cache_reported
	assert completion.data.cache_read_tokens == 900
}

fn test_session_usage_summary_sums_only_reported_completed_turns() {
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{ title: 'Usage sum', directory: '/tmp/usage-sum' }) or {
		panic(err)
	}
	first := 'd3b42ec1-8f56-45f8-9146-9a0d93f1d529'
	second := 'e4c53fd2-9067-46a9-a257-ab1ea402e63a'
	third := 'f5d640e3-a178-47ba-b368-bc2fb513f74b'
	_ = store.create_session_operation(session.id, first) or { panic(err) }
	_ = store.append_exchange(session.id, first, 'one', 'a', 'openai-compatible', 'fixture', '',
		ProviderUsage{
			input_tokens:          100
			output_tokens:         20
			cache_read_tokens:     80
			cache_creation_tokens: 10
			cache_reported:        true
			reported:              true
		}) or { panic(err) }
	_ = store.create_session_operation(session.id, second) or { panic(err) }
	_ = store.append_exchange(session.id, second, 'two', 'b', 'openai-compatible', 'fixture', '',
		ProviderUsage{
			input_tokens:  50
			output_tokens: 10
			reported:      true
		}) or { panic(err) }
	_ = store.create_session_operation(session.id, third) or { panic(err) }
	_ = store.append_exchange(session.id, third, 'three', 'c', 'openai-compatible', 'fixture', '',
		ProviderUsage{}) or { panic(err) }
	summary := store.session_usage_summary(session.id) or { panic(err) }
	assert summary.session_id == session.id
	assert summary.completed_turns == 3
	assert summary.reported_turns == 2
	assert summary.usage_reported
	assert summary.input_tokens == 150
	assert summary.output_tokens == 30
	assert summary.cache_reported
	assert summary.cache_read_tokens == 80
	assert summary.cache_creation_tokens == 10
	assert summary.cost == 'unavailable'
	empty_session := store.create_session(SessionInput{ title: 'Empty', directory: '/tmp/empty' }) or {
		panic(err)
	}
	empty := store.session_usage_summary(empty_session.id) or { panic(err) }
	assert empty.completed_turns == 0
	assert !empty.usage_reported
	assert !empty.cache_reported
	assert empty.input_tokens == 0
	assert empty.output_tokens == 0
	assert empty.cache_read_tokens == 0
}

fn test_session_operation_survives_restart_and_uncertain_work_is_not_replayed() {
	database := os.join_path(os.temp_dir(), 'veasel-operation-recovery-${uuid.new_v4().str()}.sqlite')
	defer {
		os.rm(database) or {}
		os.rm('${database}-wal') or {}
		os.rm('${database}-shm') or {}
	}
	operation_id := '4d11f39a-6b1b-4b3d-8c05-28167c15bdc2'
	mut first := open_store(database) or { panic(err) }
	session := first.create_session(SessionInput{ title: 'Recover me', directory: '/tmp/recovery' }) or {
		panic(err)
	}
	created := first.create_session_operation(session.id, operation_id) or { panic(err) }
	assert created.status == 'running'
	first.close() or { panic(err) }

	mut recovered := open_store(database) or { panic(err) }
	operation := recovered.get_session_operation(session.id, operation_id) or { panic(err) }
	assert operation.status == 'uncertain'
	assert operation.error.contains('server stopped')
	events := recovered.events_after(0) or { panic(err) }
	completions := events.filter(it.type == 'session.turn_completed')
	assert completions.len == 1
	assert completions[0].data.operation_id == operation_id
	assert completions[0].data.status == 'uncertain'
	recovered.close() or { panic(err) }

	mut reopened := open_store(database) or { panic(err) }
	defer { reopened.close() or {} }
	second_events := reopened.events_after(0) or { panic(err) }
	assert second_events.filter(it.type == 'session.turn_completed').len == 1
}

fn test_queued_session_operation_survives_restart_and_claims_to_completion() {
	database := os.join_path(os.temp_dir(), 'veasel-queued-recovery-${uuid.new_v4().str()}.sqlite')
	defer {
		os.rm(database) or {}
		os.rm('${database}-wal') or {}
		os.rm('${database}-shm') or {}
	}
	operation_id := '7c2d8e91-4a5b-4c6d-9e0f-1a2b3c4d5e6f'
	request_json := '{"content":"resume after restart","collect_trace":false,"autonomous":false}'
	mut first := open_store(database) or { panic(err) }
	session := first.create_session(SessionInput{
		title:     'Durable queue'
		directory: '/tmp/durable-queue'
	}) or { panic(err) }
	queued := first.enqueue_session_operation(session.id, operation_id, request_json) or {
		panic(err)
	}
	assert queued.status == 'queued'
	assert first.session_operation_request_json(session.id, operation_id) or { panic(err) } == request_json
	first.close() or { panic(err) }

	mut recovered := open_store(database) or { panic(err) }
	still_queued := recovered.get_session_operation(session.id, operation_id) or { panic(err) }
	assert still_queued.status == 'queued'
	assert still_queued.error == ''
	queued_list := recovered.list_queued_session_operations() or { panic(err) }
	assert queued_list.len == 1
	assert queued_list[0].id == operation_id
	listed := recovered.list_session_operations(session.id) or { panic(err) }
	assert listed.len == 1
	assert listed[0].status == 'queued'
	claimed := recovered.claim_session_operation(session.id, operation_id) or { panic(err) }
	assert claimed.status == 'running'
	_ = recovered.append_exchange(session.id, operation_id, 'resume after restart', 'done',
		'fixture', 'fixture-model', '', ProviderUsage{}) or { panic(err) }
	completed := recovered.get_session_operation(session.id, operation_id) or { panic(err) }
	assert completed.status == 'completed'
	events := recovered.events_after(0) or { panic(err) }
	assert events.filter(it.type == 'session.turn_queued').len == 1
	assert events.filter(it.type == 'session.turn_started').len == 1
	assert events.filter(it.type == 'session.turn_completed').len == 1
	assert events.filter(it.type == 'session.turn_completed')[0].data.status == 'completed'
	recovered.close() or { panic(err) }
}

fn test_enqueue_session_operation_rejects_when_queued_cap_reached() {
	mut store := open_store(':memory:') or { panic(err) }
	defer {
		store.close() or {}
	}
	session := store.create_session(SessionInput{
		title:     'Queued cap'
		directory: '/tmp/queued-cap'
	}) or { panic(err) }
	for i in 0 .. max_queued_session_operations_per_session {
		id := 'aaaaaaaa-bbbb-4ccc-8ddd-${i:012}'
		_ = store.enqueue_session_operation(session.id, id, '{"content":"queued ${i}"}') or {
			panic(err)
		}
	}
	mut rejected := false
	_ = store.enqueue_session_operation(session.id, 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff',
		'{"content":"overflow"}') or {
		rejected = err.msg() == 'queued_operations_full'
		SessionOperation{}
	}
	assert rejected
	assert (store.list_queued_session_operations() or { panic(err) }).len == max_queued_session_operations_per_session
}

fn test_enqueue_session_operation_rejects_nul_in_request_json() {
	mut store := open_store(':memory:') or { panic(err) }
	defer {
		store.close() or {}
	}
	session := store.create_session(SessionInput{
		title:     'NUL queued payload'
		directory: '/tmp/nul-queued'
	}) or { panic(err) }
	operation_id := '5e6f7081-92a3-b4c5-d6e7-f8091a2b3c4d'
	mut rejected := false
	_ = store.enqueue_session_operation(session.id, operation_id, '{"content":"bad\0json"}') or {
		rejected = err.msg() == 'queued session operation request is invalid'
		SessionOperation{}
	}
	assert rejected
	assert store.list_queued_session_operations() or { panic(err) }.len == 0
}

fn test_queued_session_operation_cancel_before_claim_is_terminal() {
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{
		title:     'Cancel queued'
		directory: '/tmp/cancel-queued'
	}) or { panic(err) }
	operation_id := '0f1e2d3c-4b5a-6978-90ab-cdef01234567'
	_ = store.enqueue_session_operation(session.id, operation_id, '{"content":"never run"}') or {
		panic(err)
	}
	status := store.cancel_session_operation(session.id, operation_id) or { panic(err) }
	assert status == 'cancelled'
	operation := store.get_session_operation(session.id, operation_id) or { panic(err) }
	assert operation.status == 'cancelled'
	assert operation.error == 'Cancelled before a worker claimed this queued turn.'
	mut claim_failed := false
	_ = store.claim_session_operation(session.id, operation_id) or {
		claim_failed = err.msg().contains('cancelled')
		SessionOperation{}
	}
	assert claim_failed
	assert store.list_queued_session_operations() or { panic(err) }.len == 0
}

fn test_resume_rejects_missing_session_workspace_without_claiming() {
	plugin_directory := os.join_path(os.temp_dir(), 'veasel-test-missing-workspace-${uuid.new_v4().str()}')
	os.mkdir_all(plugin_directory) or { panic(err) }
	defer {
		os.rmdir_all(plugin_directory) or {}
	}
	mut store := open_store(':memory:') or { panic(err) }
	defer {
		store.close() or {}
	}
	session := store.create_session(SessionInput{
		title:     'Missing workspace'
		directory: '/tmp/veasel-missing-workspace-${uuid.new_v4().str()}'
	}) or { panic(err) }
	operation_id := '4d5e6f70-8192-a3b4-c5d6-e7f8091a2b3c'
	_ = store.enqueue_session_operation(session.id, operation_id, '{"content":"still valid"}') or {
		panic(err)
	}
	mut app := new_app(store, plugin_directory)
	app.resume_durable_queued_operations()
	operation := store.get_session_operation(session.id, operation_id) or { panic(err) }
	assert operation.status == 'cancelled'
	assert operation.error == 'Queued turn session workspace is missing and will not be claimed.'
	assert store.list_queued_session_operations() or { panic(err) }.len == 0
}

fn test_resume_rejects_blank_queued_content_without_claiming() {
	plugin_directory := os.join_path(os.temp_dir(), 'veasel-test-blank-queued-${uuid.new_v4().str()}')
	workspace := os.join_path(os.temp_dir(), 'veasel-workspace-blank-queued-${uuid.new_v4().str()}')
	os.mkdir_all(plugin_directory) or { panic(err) }
	os.mkdir_all(workspace) or { panic(err) }
	defer {
		os.rmdir_all(plugin_directory) or {}
		os.rmdir_all(workspace) or {}
	}
	mut store := open_store(':memory:') or { panic(err) }
	defer {
		store.close() or {}
	}
	session := store.create_session(SessionInput{
		title:     'Blank queued content'
		directory: workspace
	}) or { panic(err) }
	operation_id := '3c4d5e6f-7081-92a3-b4c5-d6e7f8091a2b'
	_ = store.enqueue_session_operation(session.id, operation_id, '{"content":"placeholder"}') or {
		panic(err)
	}
	store.mu.lock()
	_ = store.db.exec_param_many('UPDATE session_operations SET request_json = ? WHERE id = ? AND session_id = ?',
		['{"content":"   "}', operation_id, session.id]) or { panic(err) }
	store.mu.unlock()
	mut app := new_app(store, plugin_directory)
	app.resume_durable_queued_operations()
	operation := store.get_session_operation(session.id, operation_id) or { panic(err) }
	assert operation.status == 'cancelled'
	assert operation.error == 'Queued turn request content was invalid and will not be claimed.'
	assert store.list_queued_session_operations() or { panic(err) }.len == 0
}

fn test_enqueue_session_operation_rejects_blank_content() {
	mut store := open_store(':memory:') or { panic(err) }
	defer {
		store.close() or {}
	}
	session := store.create_session(SessionInput{
		title:     'Enqueue blank'
		directory: '/tmp/enqueue-blank'
	}) or { panic(err) }
	mut rejected := false
	_ = store.enqueue_session_operation(session.id, '4d5e6f70-8192-a3b4-c5d6-e7f8091a2b3c',
		'{"content":"   "}') or {
		rejected = err.msg() == 'queued session operation request is invalid'
		SessionOperation{}
	}
	assert rejected
	assert store.list_queued_session_operations() or { panic(err) }.len == 0
}

fn test_enqueue_session_operation_rejects_non_object_json() {
	mut store := open_store(':memory:') or { panic(err) }
	defer {
		store.close() or {}
	}
	session := store.create_session(SessionInput{
		title:     'Enqueue shape'
		directory: '/tmp/enqueue-shape'
	}) or { panic(err) }
	mut rejected := false
	_ = store.enqueue_session_operation(session.id, '5e6f7081-92a3-b4c5-d6e7-f8091a2b3c4d',
		'["not","an","object"]') or {
		rejected = err.msg() == 'queued session operation request is invalid'
		SessionOperation{}
	}
	assert rejected
}

fn test_enqueue_session_operation_rejects_oversized_request_json() {
	mut store := open_store(':memory:') or { panic(err) }
	defer {
		store.close() or {}
	}
	session := store.create_session(SessionInput{
		title:     'Enqueue oversized'
		directory: '/tmp/enqueue-oversized'
	}) or { panic(err) }
	oversized := 'x'.repeat(max_chat_input_bytes + 2049)
	mut rejected := false
	_ = store.enqueue_session_operation(session.id, '6f708192-a3b4-c5d6-e7f8-091a2b3c4d5e',
		oversized) or {
		rejected = err.msg() == 'queued session operation request exceeds the size limit'
		SessionOperation{}
	}
	assert rejected
	assert store.list_queued_session_operations() or { panic(err) }.len == 0
}

fn test_resume_rejects_empty_queued_request_without_claiming() {
	plugin_directory := os.join_path(os.temp_dir(), 'veasel-test-empty-queued-${uuid.new_v4().str()}')
	workspace := os.join_path(os.temp_dir(), 'veasel-workspace-empty-queued-${uuid.new_v4().str()}')
	os.mkdir_all(plugin_directory) or { panic(err) }
	os.mkdir_all(workspace) or { panic(err) }
	defer {
		os.rmdir_all(plugin_directory) or {}
		os.rmdir_all(workspace) or {}
	}
	mut store := open_store(':memory:') or { panic(err) }
	defer {
		store.close() or {}
	}
	session := store.create_session(SessionInput{
		title:     'Empty queued payload'
		directory: workspace
	}) or { panic(err) }
	operation_id := '2b3c4d5e-6f70-8192-a3b4-c5d6e7f8091a'
	_ = store.enqueue_session_operation(session.id, operation_id, '{"content":"placeholder"}') or {
		panic(err)
	}
	store.mu.lock()
	_ = store.db.exec_param_many('UPDATE session_operations SET request_json = ? WHERE id = ? AND session_id = ?',
		['', operation_id, session.id]) or { panic(err) }
	store.mu.unlock()
	mut app := new_app(store, plugin_directory)
	app.resume_durable_queued_operations()
	operation := store.get_session_operation(session.id, operation_id) or { panic(err) }
	assert operation.status == 'cancelled'
	assert operation.error == 'Queued turn request payload is missing and will not be claimed.'
	assert store.list_queued_session_operations() or { panic(err) }.len == 0
}

fn test_resume_rejects_when_model_is_not_configured() {
	plugin_directory := os.join_path(os.temp_dir(), 'veasel-test-no-model-${uuid.new_v4().str()}')
	workspace := os.join_path(os.temp_dir(), 'veasel-workspace-no-model-${uuid.new_v4().str()}')
	os.mkdir_all(plugin_directory) or { panic(err) }
	os.mkdir_all(workspace) or { panic(err) }
	defer {
		os.rmdir_all(plugin_directory) or {}
		os.rmdir_all(workspace) or {}
	}
	mut store := open_store(':memory:') or { panic(err) }
	defer {
		store.close() or {}
	}
	session := store.create_session(SessionInput{
		title:     'No model configured'
		directory: workspace
	}) or { panic(err) }
	operation_id := '7a8b9c0d-1e2f-4a3b-8c4d-5e6f708192a3'
	_ = store.enqueue_session_operation(session.id, operation_id, '{"content":"still valid"}') or {
		panic(err)
	}
	mut app := new_app(store, plugin_directory)
	assert app.configured_model() == none
	app.resume_durable_queued_operations()
	operation := store.get_session_operation(session.id, operation_id) or { panic(err) }
	assert operation.status == 'cancelled'
	assert operation.error == 'Queued turn cannot start because a model is not configured.'
	assert store.list_queued_session_operations() or { panic(err) }.len == 0
}

fn test_resume_rejects_autonomous_when_policy_disabled() {
	plugin_directory := os.join_path(os.temp_dir(), 'veasel-test-no-auto-${uuid.new_v4().str()}')
	workspace := os.join_path(os.temp_dir(), 'veasel-workspace-no-auto-${uuid.new_v4().str()}')
	os.mkdir_all(plugin_directory) or { panic(err) }
	os.mkdir_all(workspace) or { panic(err) }
	defer {
		os.rmdir_all(plugin_directory) or {}
		os.rmdir_all(workspace) or {}
	}
	mut store := open_store(':memory:') or { panic(err) }
	defer {
		store.close() or {}
	}
	session := store.create_session(SessionInput{
		title:     'Autonomous policy off'
		directory: workspace
	}) or { panic(err) }
	operation_id := '8b9c0d1e-2f3a-4b5c-9d6e-7f8091a2b3c4'
	_ = store.enqueue_session_operation(session.id, operation_id, '{"content":"autonomous resume","autonomous":true}') or {
		panic(err)
	}
	mut app := new_app(store, plugin_directory)
	assert !app.allow_autonomous
	app.resume_durable_queued_operations()
	operation := store.get_session_operation(session.id, operation_id) or { panic(err) }
	assert operation.status == 'cancelled'
	assert operation.error == 'Queued turn cannot start because its execution policy is disabled on this server.'
	assert store.list_queued_session_operations() or { panic(err) }.len == 0
}

fn test_resume_rejects_nul_queued_request_without_claiming() {
	plugin_directory := os.join_path(os.temp_dir(), 'veasel-test-nul-queued-${uuid.new_v4().str()}')
	workspace := os.join_path(os.temp_dir(), 'veasel-workspace-nul-queued-${uuid.new_v4().str()}')
	os.mkdir_all(plugin_directory) or { panic(err) }
	os.mkdir_all(workspace) or { panic(err) }
	defer {
		os.rmdir_all(plugin_directory) or {}
		os.rmdir_all(workspace) or {}
	}
	mut store := open_store(':memory:') or { panic(err) }
	defer {
		store.close() or {}
	}
	session := store.create_session(SessionInput{
		title:     'NUL queued payload'
		directory: workspace
	}) or { panic(err) }
	operation_id := '6f708192-a3b4-c5d6-e7f8-091a2b3c4d5e'
	_ = store.enqueue_session_operation(session.id, operation_id, '{"content":"placeholder"}') or {
		panic(err)
	}
	store.mu.lock()
	_ = store.db.exec_param_many('UPDATE session_operations SET request_json = ? WHERE id = ? AND session_id = ?',
		['{"content":"bad\0json"}', operation_id, session.id]) or { panic(err) }
	store.mu.unlock()
	mut app := new_app(store, plugin_directory)
	app.resume_durable_queued_operations()
	operation := store.get_session_operation(session.id, operation_id) or { panic(err) }
	assert operation.status == 'cancelled'
	assert operation.error == 'Queued turn request was invalid and will not be claimed.'
	assert store.list_queued_session_operations() or { panic(err) }.len == 0
}

fn test_resume_rejects_invalid_queued_request_without_claiming() {
	plugin_directory := os.join_path(os.temp_dir(), 'veasel-test-invalid-queued-${uuid.new_v4().str()}')
	workspace := os.join_path(os.temp_dir(), 'veasel-workspace-invalid-queued-${uuid.new_v4().str()}')
	os.mkdir_all(plugin_directory) or { panic(err) }
	os.mkdir_all(workspace) or { panic(err) }
	defer {
		os.rmdir_all(plugin_directory) or {}
		os.rmdir_all(workspace) or {}
	}
	mut store := open_store(':memory:') or { panic(err) }
	defer {
		store.close() or {}
	}
	session := store.create_session(SessionInput{
		title:     'Invalid queued payload'
		directory: workspace
	}) or { panic(err) }
	operation_id := '1a2b3c4d-5e6f-7081-92a3-b4c5d6e7f809'
	_ = store.enqueue_session_operation(session.id, operation_id, '{"content":"placeholder"}') or {
		panic(err)
	}
	store.mu.lock()
	_ = store.db.exec_param_many('UPDATE session_operations SET request_json = ? WHERE id = ? AND session_id = ?',
		['{not-json', operation_id, session.id]) or { panic(err) }
	store.mu.unlock()
	mut app := new_app(store, plugin_directory)
	app.resume_durable_queued_operations()
	operation := store.get_session_operation(session.id, operation_id) or { panic(err) }
	assert operation.status == 'cancelled'
	assert operation.error == 'Queued turn request was invalid and will not be claimed.'
	assert store.list_queued_session_operations() or { panic(err) }.len == 0
	events := store.events_after(0) or { panic(err) }
	completions := events.filter(it.type == 'session.turn_completed')
	assert completions.len == 1
	assert completions[0].data.status == 'cancelled'
	assert completions[0].data.error == 'Queued turn request was invalid and will not be claimed.'
}

fn test_claimed_queued_operation_becomes_uncertain_after_restart() {
	database := os.join_path(os.temp_dir(), 'veasel-claimed-uncertain-${uuid.new_v4().str()}.sqlite')
	defer {
		os.rm(database) or {}
		os.rm('${database}-wal') or {}
		os.rm('${database}-shm') or {}
	}
	operation_id := 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
	mut first := open_store(database) or { panic(err) }
	session := first.create_session(SessionInput{
		title:     'Claimed then crash'
		directory: '/tmp/claimed-crash'
	}) or { panic(err) }
	_ = first.enqueue_session_operation(session.id, operation_id, '{"content":"in flight"}') or {
		panic(err)
	}
	_ = first.claim_session_operation(session.id, operation_id) or { panic(err) }
	first.close() or { panic(err) }
	mut recovered := open_store(database) or { panic(err) }
	defer { recovered.close() or {} }
	operation := recovered.get_session_operation(session.id, operation_id) or { panic(err) }
	assert operation.status == 'uncertain'
	assert recovered.list_queued_session_operations() or { panic(err) }.len == 0
}

fn test_terminal_session_operations_prune_to_retention_limit_and_keep_active() {
	mut store := open_store(':memory:') or { panic(err) }
	defer {
		store.close() or {}
	}
	store.terminal_ops_retention_limit = 3
	session := store.create_session(SessionInput{
		title:     'Prune retention'
		directory: '/tmp/prune-retention'
	}) or { panic(err) }

	oldest_id := uuid.new_v4().str()
	_ = store.create_session_operation(session.id, oldest_id) or { panic(err) }
	_ = store.append_exchange(session.id, oldest_id, 'oldest', 'done', 'openai-compatible',
		'fixture', '{"schema_version":"ATIF-v1.8","session_id":"prune"}', ProviderUsage{}) or {
		panic(err)
	}
	_ = store.operation_trace(session.id, oldest_id) or { panic(err) }

	mut kept_ids := []string{}
	for _ in 0 .. 3 {
		id := uuid.new_v4().str()
		kept_ids << id
		_ = store.create_session_operation(session.id, id) or { panic(err) }
		store.record_session_turn_completion(session.id, id, 'cancelled', 'pruned room', '',
			'') or { panic(err) }
	}

	running_id := uuid.new_v4().str()
	_ = store.create_session_operation(session.id, running_id) or { panic(err) }
	queued_id := uuid.new_v4().str()
	_ = store.enqueue_session_operation(session.id, queued_id, '{"content":"still queued"}') or {
		panic(err)
	}

	ops := store.list_session_operations(session.id) or { panic(err) }
	terminals := ops.filter(it.status in ['completed', 'failed', 'cancelled', 'uncertain'])
	assert terminals.len == 3
	for id in kept_ids {
		assert ops.any(it.id == id)
	}
	assert ops.any(it.id == running_id && it.status == 'running')
	assert ops.any(it.id == queued_id && it.status == 'queued')

	mut oldest_missing := false
	_ = store.get_session_operation(session.id, oldest_id) or {
		oldest_missing = true
		SessionOperation{}
	}
	assert oldest_missing
	mut trace_missing := false
	_ = store.operation_trace(session.id, oldest_id) or {
		trace_missing = true
		''
	}
	assert trace_missing
}

fn test_session_operation_completion_commits_with_chat_history() {
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{ title: 'Persist result', directory: '/tmp/operation' }) or {
		panic(err)
	}
	operation_id := 'a21fdf7a-cd12-49a2-9617-f60cf12b824c'
	_ = store.create_session_operation(session.id, operation_id) or { panic(err) }
	_ = store.append_exchange(session.id, operation_id, 'Question', 'Answer', 'openai-compatible',
		'fixture-model', '', ProviderUsage{}) or { panic(err) }
	mut duplicate_rejected := false
	_ = store.create_session_operation(session.id, operation_id) or {
		duplicate_rejected = err.msg() == 'session operation already exists'
		SessionOperation{}
	}
	assert duplicate_rejected
	operation := store.get_session_operation(session.id, operation_id) or { panic(err) }
	assert operation.status == 'completed'
	assert operation.provider == 'openai-compatible'
	assert operation.model == 'fixture-model'
	assert operation.error == ''
	events := store.events_after(0) or { panic(err) }
	started := events.filter(it.type == 'session.turn_started')
	assert started.len == 1
	assert started[0].data.operation_id == operation_id
	assert started[0].data.status == 'running'
	other_session := store.create_session(SessionInput{ title: 'Other session', directory: '/tmp/other' }) or {
		panic(err)
	}
	mut cross_session_lookup_failed := false
	_ = store.get_session_operation(other_session.id, operation_id) or {
		cross_session_lookup_failed = true
		SessionOperation{}
	}
	assert cross_session_lookup_failed
}

fn test_failed_session_turn_completion_event_is_persisted() {
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{ title: 'Async chat', directory: '/tmp/chat' }) or {
		panic(err)
	}
	operation_id := '7df3b3f9-68ad-466d-a115-7c8c285d1999'
	_ = store.create_session_operation(session.id, operation_id) or { panic(err) }
	store.record_session_turn_completion(session.id, operation_id, 'cancelled', 'Turn cancelled.',
		'Explain this failure', 'Turn cancelled.') or {
		panic(err)
	}
	operation := store.get_session_operation(session.id, operation_id) or { panic(err) }
	assert operation.status == 'cancelled'
	assert operation.error == 'Turn cancelled.'
	history := store.messages_for_session(session.id, 10) or { panic(err) }
	assert history.len == 2
	assert history[0].role == 'user'
	assert history[0].content == 'Explain this failure'
	assert history[1].role == 'assistant'
	assert history[1].content == 'Turn cancelled.'
	events := store.events_after(0) or { panic(err) }
	completion := events[events.len - 1]
	assert completion.type == 'session.turn_completed'
	assert completion.data.operation_id == operation_id
	assert completion.data.status == 'cancelled'
	assert completion.data.error == 'Turn cancelled.'
	assert visible_failed_turn('', 'The assistant turn failed.') == 'The assistant turn failed.'
	assert visible_failed_turn('partial', 'The assistant turn failed.') == 'partial\nThe assistant turn failed.'
	assert visible_failed_turn('partial\n', 'The assistant turn failed.') == 'partial\nThe assistant turn failed.'
	assert tool_round_text_boundary('') == ''
	assert tool_round_text_boundary('Looking.') == '\n'
	assert tool_round_text_boundary('Looking.\n') == ''
}

fn test_model_endpoint_requires_tls_or_exact_loopback() {
	assert secure_endpoint('https://api.example.test/v1') or { panic(err) } == 'https://api.example.test/v1'
	assert secure_endpoint('https://api.example.test/v1/') or { panic(err) } == 'https://api.example.test/v1'
	assert secure_endpoint('http://localhost:11434/v1') or { panic(err) } == 'http://localhost:11434/v1'
	assert secure_endpoint('http://127.0.0.1:8080/v1') or { panic(err) } == 'http://127.0.0.1:8080/v1'
	assert secure_endpoint('http://[::1]:8080/v1') or { panic(err) } == 'http://[::1]:8080/v1'
	assert model_endpoint_rejected('http://example.test/v1')
	assert model_endpoint_rejected('http://localhost.attacker.test/v1')
	assert model_endpoint_rejected('http://127.0.0.10/v1')
	assert model_endpoint_rejected('https://user:secret@example.test/v1')
	assert model_endpoint_rejected('https://api.example.test/v1?token=secret')
	assert model_endpoint_rejected('https://api.example.test/v1#fragment')
	assert model_endpoint_rejected('ftp://api.example.test/v1')
	assert model_endpoint_rejected('not a URL')
	assert model_endpoint_rejected('https://api.example.test/v1\nbad')
	assert model_endpoint_rejected('https://api.example.test/\0path')
	assert model_endpoint_rejected('https://api.example.test/v1\ttrail')
}

fn test_local_api_accepts_only_loopback_host_and_origin() {
	assert is_loopback_host('127.0.0.1:4097')
	assert is_loopback_host('localhost:4097')
	assert is_loopback_host('[::1]:4097')
	assert !is_loopback_host('localhost.attacker.test')
	assert !is_loopback_host('127.0.0.10:4097')
	assert is_loopback_origin('http://127.0.0.1:8080')
	assert is_loopback_origin('http://localhost:3000')
	assert !is_loopback_origin('https://localhost:3000')
	assert !is_loopback_origin('http://localhost.attacker.test')
	assert !is_loopback_origin('http://127.0.0.1:8080/path')
}

fn model_endpoint_rejected(base_url string) bool {
	_ := secure_endpoint(base_url) or { return true }
	return false
}

fn test_chat_input_is_bounded_and_ends_with_user_turn() {
	validate_messages([ChatMessage{ role: 'user', content: 'Hello' }]) or { panic(err) }
	assert chat_input_rejected([])
	assert chat_input_rejected([ChatMessage{ role: 'assistant', content: 'Unprompted' }])
	assert chat_input_rejected([ChatMessage{ role: 'tool', content: 'Not allowed' }])
	assert chat_input_rejected([ChatMessage{ role: 'user', content: '   ' }])
	assert chat_input_rejected([ChatMessage{
		role:    'user'
		content: 'before\0after'
	}])
}

fn test_workspace_root_is_canonical_and_must_exist() {
	root := canonical_workspace_root(os.getwd()) or { panic(err) }
	assert root == os.real_path(os.getwd())
	assert os.is_abs_path(root)
	temp_root := os.join_path(os.temp_dir(), 'veasel-workspace-${uuid.new_v4().str()}')
	alias := os.join_path(os.temp_dir(), 'veasel-workspace-link-${uuid.new_v4().str()}')
	os.mkdir_all(temp_root) or { panic(err) }
	defer { os.rmdir_all(temp_root) or {} }
	os.symlink(temp_root, alias) or { panic(err) }
	defer { os.rm(alias) or {} }
	canonical_alias := canonical_workspace_root(alias) or { panic(err) }
	assert canonical_alias == os.real_path(temp_root)
	$if !windows {
		spaced_root := os.join_path(os.temp_dir(), 'veasel-workspace-${uuid.new_v4().str()} ')
		os.mkdir_all(spaced_root) or { panic(err) }
		defer { os.rmdir_all(spaced_root) or {} }
		canonical_spaced_root := canonical_workspace_root(spaced_root) or { panic(err) }
		assert canonical_spaced_root == os.real_path(spaced_root)
	}
	missing := os.join_path(os.temp_dir(), 'veasel-missing-${uuid.new_v4().str()}')
	assert workspace_root_rejected(missing)
}

fn workspace_root_rejected(path string) bool {
	_ := canonical_workspace_root(path) or { return true }
	return false
}

fn chat_input_rejected(messages []ChatMessage) bool {
	validate_messages(messages) or { return true }
	return false
}
