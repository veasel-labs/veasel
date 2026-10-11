module main

import os
import json2
import context as vcontext
import sync
import uuid
import time

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
	exchange := store.append_exchange(session.id, 'What is this?', 'A test reply.') or { panic(err) }
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
