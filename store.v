module main

import db.sqlite
import os
import sync
import uuid

pub struct Session {
pub:
	id         string
	title      string
	directory  string
	created_at string
}

pub struct ChatTurn {
pub:
	id         int
	session_id string
	role       string
	content    string
	created_at string
}

struct SessionInput {
pub:
	title     string
	directory string
}

struct Event {
pub:
	id         int
	type       string
	session_id string
	created_at string
}

@[heap]
struct Store {
mut:
	mu sync.Mutex
	db sqlite.DB
}

fn open_store(path string) !&Store {
	if path != ':memory:' {
		os.mkdir_all(os.dir(path))!
	}
	mut db := sqlite.connect(path)!
	if db.busy_timeout(5000) != sqlite.sqlite_ok {
		db.close() or {}
		return error('unable to configure SQLite busy timeout')
	}
	db.exec('PRAGMA journal_mode=WAL') or {
		db.close() or {}
		return error('unable to configure SQLite journal mode')
	}
	db.exec('PRAGMA foreign_keys=ON') or {
		db.close() or {}
		return error('unable to enable SQLite foreign keys')
	}
	db.exec('CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)') or {
		db.close() or {}
		return error('unable to initialize migration ledger')
	}
	current := db.q_int('SELECT COALESCE(MAX(version), 0) FROM schema_migrations') or {
		db.close() or {}
		return error('unable to read migration version')
	}
	if current < 1 {
		db.begin() or {
			db.close() or {}
			return error('unable to begin database migration')
		}
		db.exec('CREATE TABLE sessions (id TEXT PRIMARY KEY, title TEXT NOT NULL, directory TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to create sessions table')
		}
		db.exec('CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL, session_id TEXT NOT NULL REFERENCES sessions(id), created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to create events table')
		}
		db.exec('INSERT INTO schema_migrations (version) VALUES (1)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to record initial migration')
		}
		db.commit() or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to commit initial migration')
		}
	}
	if current < 2 {
		db.begin() or {
			db.close() or {}
			return error('unable to begin chat history migration')
		}
		db.exec("CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL REFERENCES sessions(id), role TEXT NOT NULL CHECK (role IN ('user', 'assistant')), content TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)") or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to create messages table')
		}
		db.exec('CREATE INDEX messages_session_id_id ON messages(session_id, id)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to index chat history')
		}
		db.exec('INSERT INTO schema_migrations (version) VALUES (2)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to record chat history migration')
		}
		db.commit() or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to commit chat history migration')
		}
	}
	return &Store{
		db: db
	}
}

fn (mut store Store) close() ! {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	store.db.close()!
}

fn (mut store Store) create_session(input SessionInput) !Session {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	id := uuid.new_v4().str()
	store.db.begin()!
	_ = store.db.exec_param_many('INSERT INTO sessions (id, title, directory) VALUES (?, ?, ?)',
		[id, input.title, input.directory]) or {
		store.db.rollback() or {}
		return error('unable to write session')
	}
	_ = store.db.exec_param2('INSERT INTO events (type, session_id) VALUES (?, ?)', 'session.created',
		id) or {
		store.db.rollback() or {}
		return error('unable to write session event')
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit session')
	}
	rows := store.db.exec_param('SELECT id, title, directory, created_at FROM sessions WHERE id = ?',
		id)!
	if rows.len != 1 {
		return error('created session could not be read')
	}
	row := rows[0]
	return Session{
		id:         row.val(0)
		title:      row.val(1)
		directory:  row.val(2)
		created_at: row.val(3)
	}
}

fn (mut store Store) list_sessions() ![]Session {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	rows := store.db.exec('SELECT id, title, directory, created_at FROM sessions ORDER BY created_at DESC, id DESC')!
	mut sessions := []Session{cap: rows.len}
	for row in rows {
		sessions << Session{
			id:         row.val(0)
			title:      row.val(1)
			directory:  row.val(2)
			created_at: row.val(3)
		}
	}
	return sessions
}

fn (mut store Store) get_session(id string) !Session {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	rows := store.db.exec_param('SELECT id, title, directory, created_at FROM sessions WHERE id = ?',
		id)!
	if rows.len == 0 {
		return error('session not found')
	}
	row := rows[0]
	return Session{
		id:         row.val(0)
		title:      row.val(1)
		directory:  row.val(2)
		created_at: row.val(3)
	}
}

fn (mut store Store) events_after(after int) ![]Event {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	rows := store.db.exec_param('SELECT id, type, session_id, created_at FROM events WHERE id > ? ORDER BY id LIMIT 100',
		after.str())!
	mut events := []Event{cap: rows.len}
	for row in rows {
		events << Event{
			id:         row.val(0).int()
			type:       row.val(1)
			session_id: row.val(2)
			created_at: row.val(3)
		}
	}
	return events
}

fn (mut store Store) messages_for_session(session_id string, limit int) ![]ChatTurn {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	rows := store.db.exec_param_many('SELECT id, session_id, role, content, created_at FROM (SELECT id, session_id, role, content, created_at FROM messages WHERE session_id = ? ORDER BY id DESC LIMIT ?) ORDER BY id',
		[session_id, limit.str()])!
	mut messages := []ChatTurn{cap: rows.len}
	for row in rows {
		messages << ChatTurn{
			id:         row.val(0).int()
			session_id: row.val(1)
			role:       row.val(2)
			content:    row.val(3)
			created_at: row.val(4)
		}
	}
	return messages
}

fn (mut store Store) append_exchange(session_id string, user_content string, assistant_content string) ![]ChatTurn {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	store.db.begin()!
	sessions := store.db.exec_param('SELECT id FROM sessions WHERE id = ?', session_id) or {
		store.db.rollback() or {}
		return error('session not found')
	}
	if sessions.len != 1 {
		store.db.rollback() or {}
		return error('session not found')
	}
	for turn in [ChatTurn{
		role:    'user'
		content: user_content
	}, ChatTurn{
		role:    'assistant'
		content: assistant_content
	}] {
		_ = store.db.exec_param_many('INSERT INTO messages (session_id, role, content) VALUES (?, ?, ?)',
			[session_id, turn.role, turn.content]) or {
			store.db.rollback() or {}
			return error('unable to persist chat turn')
		}
		_ = store.db.exec_param2('INSERT INTO events (type, session_id) VALUES (?, ?)', 'message.created',
			session_id) or {
			store.db.rollback() or {}
			return error('unable to persist chat event')
		}
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit chat exchange')
	}
	rows := store.db.exec_param('SELECT id, session_id, role, content, created_at FROM messages WHERE session_id = ? ORDER BY id DESC LIMIT 2',
		session_id)!
	mut result := []ChatTurn{cap: rows.len}
	for row in rows {
		result << ChatTurn{
			id:         row.val(0).int()
			session_id: row.val(1)
			role:       row.val(2)
			content:    row.val(3)
			created_at: row.val(4)
		}
	}
	result = result.reverse()
	return result
}
