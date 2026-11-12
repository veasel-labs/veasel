module main

import context as vcontext
import json2
import net.http
import os
import sync
import time
import uuid

struct ContextHandoffProviderFixture {
mut:
	mu            sync.Mutex
	requests      []string
	parent_a_hits int
	parent_b_hits int
	child_b_hits  int
}

fn (mut fixture ContextHandoffProviderFixture) handle(request http.Request) http.Response {
	fixture.mu.lock()
	fixture.requests << '${request.url}\n${request.data}'
	is_child := request.data.contains('You are a read-only Veasel Code')
	mut parent_a_hit := 0
	if is_child {
		fixture.child_b_hits++
	} else if request.data.contains('"model":"model-a-default"') {
		fixture.parent_a_hits++
		parent_a_hit = fixture.parent_a_hits
	} else if request.data.contains('"model":"model-b"') {
		fixture.parent_b_hits++
	}
	fixture.mu.unlock()
	mut delta := OpenAIStreamDelta{}
	if !is_child && parent_a_hit == 1 {
		delta = OpenAIStreamDelta{
			tool_calls: [OpenAIStreamToolCallDelta{
				index:    0
				id:       'call-child-b'
				type:     'function'
				function: OpenAIStreamFunctionDelta{
					name:      'subagent_run'
					arguments: '{"agent_id":"explorer","task":"Read README.md and summarize its contents.","provider":"deepseek","model":"model-b"}'
				}
			}]
		}
	} else {
		answer := if is_child {
			'Child B reports the README marker: BLUE-MOON.'
		} else if request.data.contains('"model":"model-a-default"') {
			'Parent A answer includes the child B result: BLUE-MOON.'
		} else if request.data.contains('"model":"model-b"') {
			'Parent B continued the same conversation.'
		} else {
			'Parent C received the continued conversation.'
		}
		delta = OpenAIStreamDelta{ content: answer }
	}
	chunk := OpenAIStreamChunk{
		choices: [OpenAIStreamChoice{ delta: delta }]
		usage:   OpenAIUsage{
			prompt_tokens:     i64(10)
			completion_tokens: i64(3)
			total_tokens:      i64(13)
		}
	}
	mut response := http.Response{}
	response.set_status(.ok)
	response.header.set(.content_type, 'text/event-stream')
	response.body = 'data: ${json2.encode(chunk)}\n\ndata: [DONE]\n\n'
	return response
}

fn start_context_handoff_provider_fixture(mut fixture ContextHandoffProviderFixture) !(&http.Server, thread) {
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

fn test_context_handoff_a_to_b_to_c_routes_parent_turns_and_keeps_context_identity() {
	root := os.join_path(os.temp_dir(), 'veasel-context-handoff-runtime-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	workspace := init_context_handoff_runtime_repo(root)
	os.mkdir_all(os.join_path(root, 'plugins')) or { panic(err) }
	mut fixture := &ContextHandoffProviderFixture{}
	mut server, server_thread := start_context_handoff_provider_fixture(mut fixture) or {
		panic(err)
	}
	defer {
		server.stop()
		server_thread.wait()
	}
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	mut app := new_app(store, os.join_path(root, 'plugins'))
	defer { app.close() }
	base_url := 'http://${server.addr}/v1'
	app.model_settings.update(ModelSettingsInput{
		provider: 'openai-compatible'
		model:    'model-a-default'
		base_url: base_url
		api_key:  'fixture-key'
	}) or { panic(err) }
	for profile in [
		ModelSettingsInput{ provider: 'deepseek', model: 'model-b', base_url: base_url, api_key: 'fixture-key' },
		ModelSettingsInput{ provider: 'openai', model: 'model-c', base_url: base_url, api_key: 'fixture-key' },
	] {
		app.model_settings.update(profile) or { panic(err) }
	}
	// Updating provider profiles does not change the active default; restore A
	// as the default that omitted targets inherit.
	app.model_settings.update(ModelSettingsInput{
		provider: 'openai-compatible'
		model:    'model-a-default'
		base_url: base_url
		api_key:  'fixture-key'
	}) or { panic(err) }
	parent := store.create_session(SessionInput{ title: 'Cross-provider parent', directory: workspace }) or {
		panic(err)
	}
	policy_input := fn (content string) ChatMessageInput {
		return ChatMessageInput{
			content:          content
			execution_policy: 'ask'
		}
	}
	op_a := uuid.new_v4().str()
	exchange_a := run_context_handoff_test_turn(mut app, parent, op_a,
		policy_input('Question asked on A')) or { panic(err) }
	assert exchange_a.provider == 'openai-compatible'
	assert exchange_a.model == 'model-a-default'
	child_rows := store.db.exec_param_many('SELECT id, child_session_id FROM subagent_runs WHERE parent_session_id = ? AND parent_operation_id = ?',
		[parent.id, op_a]) or { panic(err) }
	assert child_rows.len == 1
	child_run := wait_for_context_handoff_child(mut store, child_rows[0].val(0))
	assert child_run.status == 'completed'
	assert child_run.provider == 'deepseek'
	assert child_run.model == 'model-b'
	assert child_run.result == 'Child B reports the README marker: BLUE-MOON.'
	child_operations := store.list_session_operations(child_rows[0].val(1)) or { panic(err) }
	assert child_operations.len == 1
	assert child_operations[0].provider == 'deepseek'
	assert child_operations[0].model == 'model-b'
	op_b := uuid.new_v4().str()
	exchange_b := run_context_handoff_test_turn(mut app, parent, op_b, ChatMessageInput{
		content:          'Continue this conversation on B'
		provider:         'deepseek'
		model:            'model-b'
		execution_policy: 'ask'
	}) or { panic(err) }
	assert exchange_b.provider == 'deepseek'
	assert exchange_b.model == 'model-b'
	op_c := uuid.new_v4().str()
	exchange_c := run_context_handoff_test_turn(mut app, parent, op_c, ChatMessageInput{
		content:          'Continue the same conversation on C'
		provider:         'openai'
		model:            'model-c'
		execution_policy: 'ask'
	}) or { panic(err) }
	assert exchange_c.provider == 'openai'
	assert exchange_c.model == 'model-c'
	assert app.model_config() or { panic(err) }.provider == 'openai-compatible'
	assert app.model_config() or { panic(err) }.model == 'model-a-default'
	operations := store.list_session_operations(parent.id) or { panic(err) }
	assert operations.len == 3
	assert operations[0].provider == 'openai-compatible'
	assert operations[0].model == 'model-a-default'
	assert operations[1].provider == 'deepseek'
	assert operations[1].model == 'model-b'
	assert operations[2].provider == 'openai'
	assert operations[2].model == 'model-c'
	handoffs := store.list_retained_context_handoffs(parent.id) or { panic(err) }
	assert handoffs.len == 2
	assert handoffs[0].session_id == parent.id
	assert handoffs[0].source_operation_id == op_a
	assert handoffs[0].next_operation_id == op_b
	assert handoffs[0].source_provider == 'openai-compatible'
	assert handoffs[0].target_provider == 'deepseek'
	assert handoffs[0].context_mode == 'full'
	assert handoffs[0].transcript.any(it.content == 'Question asked on A')
	assert handoffs[0].transcript.any(it.content.contains('child B result: BLUE-MOON'))
	assert handoffs[0].permission_policy_mode == 'ask'
	assert handoffs[1].source_operation_id == op_b
	assert handoffs[1].next_operation_id == op_c
	assert handoffs[1].source_provider == 'deepseek'
	assert handoffs[1].target_provider == 'openai'
	assert handoffs[1].context_mode == 'delta'
	assert handoffs[1].transcript.any(it.content == 'Continue this conversation on B')
	assert handoffs.all(!it.hidden_reasoning_transferred && it.permissions_inherited)
	assert fixture.requests.len == 5
	assert fixture.requests[0].contains('"model":"model-a-default"')
	assert fixture.requests.any(it.contains('"model":"model-b"') && it.contains('read-only Veasel Code'))
	assert fixture.requests.any(it.contains('"model":"model-b"') && !it.contains('read-only Veasel Code'))
	assert fixture.requests.any(it.contains('"model":"model-c"'))
	// The handoff artifact is a durable checkpoint; model requests still use the
	// canonical bounded session history assembled by the runtime. Verify the
	// actual C request carries both earlier parent turns and the delivered child
	// result, rather than treating artifact contents as proof of dispatch.
	c_requests := fixture.requests.filter(it.contains('"model":"model-c"'))
	assert c_requests.len == 1
	c_request := c_requests[0]
	assert c_request.contains('Question asked on A')
	assert c_request.contains('Parent A answer includes the child B result: BLUE-MOON.')
	assert c_request.contains('Continue this conversation on B')
	assert c_request.contains('Parent B continued the same conversation.')
	assert c_request.contains('Continue the same conversation on C')
	assert fixture.child_b_hits == 1
	assert fixture.parent_b_hits == 1
	store.session_events_retention_limit = 1
	prune_context_handoff_test_events(mut store, parent.id)
	event_rows := store.db.exec_param_many('SELECT id FROM events WHERE session_id = ? AND type = ?',
		[parent.id, context_handoff_event_type]) or { panic(err) }
	assert event_rows.len == 0
	retained := store.list_retained_context_handoffs(parent.id) or { panic(err) }
	assert retained.map(it.artifact_id) == handoffs.map(it.artifact_id)
}

fn wait_for_context_handoff_child(mut store Store, run_id string) SubagentRun {
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

fn prune_context_handoff_test_events(mut store Store, session_id string) {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	_ = store.db.exec_param_many('INSERT INTO events (type, session_id, data) VALUES (?, ?, ?)', [
		'test.context_handoff_retention_probe',
		session_id,
		'{}',
	]) or { panic(err) }
	store.prune_session_events_unlocked(session_id)
}

fn run_context_handoff_test_turn(mut app App, parent Session, operation_id string,
	input ChatMessageInput) !ChatExchange {
	mut store := app.store
	_ := store.create_session_operation(parent.id, operation_id)!
	mut background := vcontext.background()
	mut turn_ctx, cancel := vcontext.with_timeout(mut background, 20 * time.second)
	defer { cancel() }
	return app.run_session_message(mut turn_ctx, parent.id, parent, input, operation_id,
		turn_ctx.deadline() or { return error('expected turn deadline') })
}

fn test_per_turn_route_requires_provider_and_model_and_validates_credentials_early() {
	previous_shared_key := os.getenv_opt('VEASEL_MODEL_API_KEY') or { '' }
	previous_anthropic_key := os.getenv_opt('ANTHROPIC_API_KEY') or { '' }
	os.setenv('VEASEL_MODEL_API_KEY', '', true)
	os.setenv('ANTHROPIC_API_KEY', '', true)
	defer {
		os.setenv('VEASEL_MODEL_API_KEY', previous_shared_key, true)
		os.setenv('ANTHROPIC_API_KEY', previous_anthropic_key, true)
	}
	root := os.join_path(os.temp_dir(), 'veasel-context-handoff-invalid-${uuid.new_v4().str()}')
	os.mkdir_all(os.join_path(root, 'plugins')) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	mut app := new_app(store, os.join_path(root, 'plugins'))
	defer { app.close() }
	for input in [
		ChatMessageInput{ content: 'partial', provider: 'openai' },
		ChatMessageInput{ content: 'partial', model: 'gpt-test' },
	] {
		if _ := app.model_config_for_chat_input('session-id', input) {
			assert false, 'partial model targets must be rejected'
		} else {
			assert err.msg() == 'provider and model must be supplied together'
		}
	}
	if _ := app.model_config_for_chat_input('session-id', ChatMessageInput{
		content:  'unconfigured'
		provider: 'anthropic'
		model:    'claude-test'
	}) {
		assert false, 'missing provider credentials must be rejected before turn creation'
	} else {
		assert err.msg().contains('credentials are not configured')
	}
}

fn test_context_handoff_migration_copies_legacy_event_artifacts_into_retained_table() {
	root := os.join_path(os.temp_dir(), 'veasel-context-handoff-migration-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	workspace := init_context_handoff_runtime_repo(root)
	database := os.join_path(root, 'veasel.sqlite3')
	mut store := open_store(database) or { panic(err) }
	parent := store.create_session(SessionInput{ title: 'Legacy handoff', directory: workspace }) or {
		panic(err)
	}
	op_a := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, op_a) or { panic(err) }
	_ = store.append_exchange(parent.id, op_a, 'Legacy question', 'Legacy answer', 'anthropic',
		'claude-test', '', ProviderUsage{}) or { panic(err) }
	op_b := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, op_b) or { panic(err) }
	legacy := store.persist_context_handoff(parent.id, op_b, 'google', 'gemini-test',
		ExecutionPolicyTurn{ mode: .ask, interactive: true }, 'parent_turn') or { panic(err) }
	store.db.exec('DROP TABLE context_handoffs') or { panic(err) }
	store.db.exec('DROP TABLE agent_token_budget_reservations') or { panic(err) }
	store.db.exec('DELETE FROM schema_migrations WHERE version = 27') or { panic(err) }
	store.db.exec('DELETE FROM schema_migrations WHERE version = 28') or { panic(err) }
	store.close() or { panic(err) }
	mut migrated := open_store(database) or { panic(err) }
	defer { migrated.close() or {} }
	recovered := migrated.list_retained_context_handoffs(parent.id) or { panic(err) }
	assert recovered.len == 1
	assert recovered[0].artifact_id == legacy.artifact_id
	assert recovered[0].source_provider == 'anthropic'
	assert recovered[0].target_provider == 'google'
}

fn test_incomplete_previous_handoff_forces_bounded_full_context_fallback() {
	root := os.join_path(os.temp_dir(), 'veasel-context-handoff-incomplete-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	workspace := init_context_handoff_runtime_repo(root)
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	parent := store.create_session(SessionInput{ title: 'Incomplete checkpoint', directory: workspace }) or {
		panic(err)
	}
	op_a := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, op_a) or { panic(err) }
	_ = store.append_exchange(parent.id, op_a, 'Question on A', 'Answer from A', 'provider-a',
		'model-a', '', ProviderUsage{}) or { panic(err) }
	op_b := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, op_b) or { panic(err) }
	policy := ExecutionPolicyTurn{ mode: .ask, interactive: true }
	first := store.persist_context_handoff_retained(parent.id, op_b, 'provider-b', 'model-b',
		policy, 'parent_turn') or { panic(err) }
	_ = store.append_exchange(parent.id, op_b, 'Question on B', 'Answer from B', 'provider-b',
		'model-b', '', ProviderUsage{}) or { panic(err) }
	incomplete := store.retained_context_handoff_for_operation(parent.id, op_b) or { panic(err) }
	encoded := json2.encode(incomplete).replace('"transcript_complete":true',
		'"transcript_complete":false')
	assert encoded.contains('"transcript_complete":false')
	_ = store.db.exec_param_many('UPDATE context_handoffs SET artifact_json = ? WHERE session_id = ? AND next_operation_id = ?', [
		encoded,
		parent.id,
		op_b,
	]) or { panic(err) }
	op_c := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, op_c) or { panic(err) }
	second := store.persist_context_handoff_retained(parent.id, op_c, 'provider-c', 'model-c', policy,
		'parent_turn') or { panic(err) }
	assert first.context_mode == 'full'
	assert second.context_mode == 'full'
	assert second.fallback_reason == 'previous handoff checkpoint was incomplete; using a bounded full-context snapshot'
	assert second.transcript.any(it.content == 'Question on A')
	assert second.transcript.any(it.content == 'Answer from A')
	assert second.transcript.any(it.content == 'Question on B')
	assert second.transcript.any(it.content == 'Answer from B')
}

fn init_context_handoff_runtime_repo(root string) string {
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
