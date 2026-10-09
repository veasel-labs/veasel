module main

import os
import sync
import uuid

fn test_session_turn_lock_stripes_serialize_the_same_session() {
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
	first.lock()
	assert !second.try_lock()
	first.unlock()
	assert second.try_lock()
	second.unlock()
	assert session_turn_lock_index('session-a') >= 0
	assert session_turn_lock_index('session-a') < session_turn_lock_stripes
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
	assert secure_endpoint('http://localhost:11434/v1') or { panic(err) } == 'http://localhost:11434/v1'
	assert secure_endpoint('http://127.0.0.1:8080/v1') or { panic(err) } == 'http://127.0.0.1:8080/v1'
	assert secure_endpoint('http://[::1]:8080/v1') or { panic(err) } == 'http://[::1]:8080/v1'
	assert model_endpoint_rejected('http://localhost.attacker.test/v1')
	assert model_endpoint_rejected('http://127.0.0.10/v1')
	assert model_endpoint_rejected('https://user:secret@example.test/v1')
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
	spaced_root := os.join_path(os.temp_dir(), 'veasel-workspace-${uuid.new_v4().str()} ')
	os.mkdir_all(spaced_root) or { panic(err) }
	defer { os.rmdir_all(spaced_root) or {} }
	canonical_spaced_root := canonical_workspace_root(spaced_root) or { panic(err) }
	assert canonical_spaced_root == os.real_path(spaced_root)
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
