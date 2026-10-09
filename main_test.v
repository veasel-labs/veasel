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
