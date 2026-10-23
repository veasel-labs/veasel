module main

import os

fn test_session_operation_recovery_keeps_submission_order_when_timestamps_tie() {
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{
		title:     'Recovery order'
		directory: os.temp_dir()
	}) or { panic(err) }
	// UUID lexical order must not decide which follow-up is newest after restart.
	first := 'ffffffff-ffff-4fff-8fff-ffffffffffff'
	second := '00000000-0000-4000-8000-000000000000'
	_ = store.enqueue_session_operation(session.id, first, '{"content":"first"}') or { panic(err) }
	_ = store.enqueue_session_operation(session.id, second, '{"content":"second"}') or { panic(err) }
	store.db.exec("UPDATE session_operations SET created_at = '2026-10-28 00:00:00'") or { panic(err) }
	operations := store.list_session_operations(session.id) or { panic(err) }
	assert operations.map(it.id) == [first, second]
}
