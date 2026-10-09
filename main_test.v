module main

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

fn chat_input_rejected(messages []ChatMessage) bool {
	validate_messages(messages) or { return true }
	return false
}
