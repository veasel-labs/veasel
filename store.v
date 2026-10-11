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

pub struct SessionPluginSkill {
pub:
	plugin_name string
	skill_name  string
}

pub struct SessionPluginMCPServer {
pub:
	plugin_name string
	server_name string
}

@[heap]
struct Store {
mut:
	mu sync.Mutex
	db sqlite.DB
}

struct InterruptedWorkspaceEdit {
	id          string
	path        string
	root        string
	create_file bool
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
	if current < 3 {
		db.begin() or {
			db.close() or {}
			return error('unable to begin plugin skill migration')
		}
		db.exec('CREATE TABLE session_plugin_skills (session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, plugin_name TEXT NOT NULL, skill_name TEXT NOT NULL, enabled_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (session_id, plugin_name, skill_name))') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to create session plugin skill table')
		}
		db.exec('INSERT INTO schema_migrations (version) VALUES (3)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to record plugin skill migration')
		}
		db.commit() or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to commit plugin skill migration')
		}
	}
	if current < 4 {
		db.begin() or {
			db.close() or {}
			return error('unable to begin workspace edit migration')
		}
		db.exec("CREATE TABLE workspace_edits (id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, path TEXT NOT NULL, expected_hash TEXT NOT NULL, content TEXT NOT NULL, diff TEXT NOT NULL, create_file INTEGER NOT NULL CHECK (create_file IN (0, 1)), status TEXT NOT NULL CHECK (status IN ('pending', 'applying', 'applied', 'rejected', 'conflict', 'interrupted')), reviewed_at TEXT, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)") or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to create workspace edit table')
		}
		db.exec('CREATE INDEX workspace_edits_session_created ON workspace_edits (session_id, created_at, id)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to index workspace edits')
		}
		db.exec('INSERT INTO schema_migrations (version) VALUES (4)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to record workspace edit migration')
		}
		db.commit() or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to commit workspace edit migration')
		}
	}
	if current < 5 {
		db.begin() or {
			db.close() or {}
			return error('unable to begin plugin MCP trust migration')
		}
		db.exec('CREATE TABLE session_plugin_mcp_servers (session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, plugin_name TEXT NOT NULL, server_name TEXT NOT NULL, trusted_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (session_id, plugin_name, server_name))') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to create session plugin MCP trust table')
		}
		db.exec('INSERT INTO schema_migrations (version) VALUES (5)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to record plugin MCP trust migration')
		}
		db.commit() or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to commit plugin MCP trust migration')
		}
	}
	if current < 6 {
		db.begin() or {
			db.close() or {}
			return error('unable to begin shell command migration')
		}
		db.exec("CREATE TABLE shell_commands (id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, command TEXT NOT NULL, cwd TEXT NOT NULL, timeout_seconds INTEGER NOT NULL, status TEXT NOT NULL CHECK (status IN ('pending', 'running', 'succeeded', 'failed', 'timed_out', 'output_limited', 'rejected', 'uncertain')), exit_code INTEGER NOT NULL DEFAULT -1, output TEXT NOT NULL DEFAULT '', reviewed_at TEXT, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)") or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to create shell command table')
		}
		db.exec('CREATE INDEX shell_commands_session_created ON shell_commands (session_id, created_at, id)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to index shell commands')
		}
		db.exec('INSERT INTO schema_migrations (version) VALUES (6)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to record shell command migration')
		}
		db.commit() or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to commit shell command migration')
		}
	}
	if current >= 6 {
		db.begin() or {
			db.close() or {}
			return error('unable to begin shell command recovery')
		}
		uncertain := db.exec("SELECT id, session_id FROM shell_commands WHERE status = 'running'") or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to inspect interrupted shell commands')
		}
		for row in uncertain {
			_ = db.exec_param_many("UPDATE shell_commands SET status = 'uncertain', updated_at = CURRENT_TIMESTAMP WHERE id = ? AND status = 'running'", [row.val(0)]) or {
				db.rollback() or {}
				db.close() or {}
				return error('unable to recover interrupted shell command')
			}
			_ = db.exec_param_many('INSERT INTO events (type, session_id) VALUES (?, ?)', [
				'shell.command_uncertain',
				row.val(1),
			]) or {
				db.rollback() or {}
				db.close() or {}
				return error('unable to record interrupted shell command')
			}
		}
		db.commit() or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to commit shell command recovery')
		}
	}
	if current >= 4 {
		pending_recovery := db.exec("SELECT e.id, e.path, e.create_file, s.directory FROM workspace_edits e JOIN sessions s ON s.id = e.session_id WHERE e.status IN ('applying', 'interrupted')") or {
			db.close() or {}
			return error('unable to inspect interrupted workspace edit backups')
		}
		mut recoveries := []InterruptedWorkspaceEdit{cap: pending_recovery.len}
		for row in pending_recovery {
			recoveries << InterruptedWorkspaceEdit{
				id:          row.val(0)
				path:        row.val(1)
				create_file: row.val(2).int() == 1
				root:        row.val(3)
			}
		}
		for recovery in recoveries {
			if !recovery.create_file {
				recover_interrupted_workspace_edit(recovery.root, recovery.id, recovery.path)
			}
		}
		db.begin() or {
			db.close() or {}
			return error('unable to begin workspace edit recovery')
		}
		interrupted := db.exec("SELECT id, session_id FROM workspace_edits WHERE status = 'applying'") or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to inspect interrupted workspace edits')
		}
		mut interrupted_ids := []string{cap: interrupted.len}
		mut interrupted_sessions := []string{cap: interrupted.len}
		for row in interrupted {
			interrupted_ids << row.val(0)
			interrupted_sessions << row.val(1)
		}
		for index, id in interrupted_ids {
			_ = db.exec_param_many("UPDATE workspace_edits SET status = 'interrupted', updated_at = CURRENT_TIMESTAMP WHERE id = ? AND status = 'applying'",
				[id]) or {
				db.rollback() or {}
				db.close() or {}
				return error('unable to recover interrupted workspace edit')
			}
			_ = db.exec_param_many('INSERT INTO events (type, session_id) VALUES (?, ?)',
				['workspace.edit_interrupted', interrupted_sessions[index]]) or {
				db.rollback() or {}
				db.close() or {}
				return error('unable to record interrupted workspace edit')
			}
		}
		db.commit() or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to commit workspace edit recovery')
		}
	}
	return &Store{
		db: db
	}
}

fn (mut store Store) create_shell_command(session_id string, draft ShellCommandDraft) !ShellCommandSummary {
	store.mu.lock()
	defer { store.mu.unlock() }
	store.db.begin()!
	sessions := store.db.exec_param('SELECT id FROM sessions WHERE id = ?', session_id) or {
		store.db.rollback() or {}
		return error('session not found')
	}
	if sessions.len != 1 {
		store.db.rollback() or {}
		return error('session not found')
	}
	pending := store.db.exec_param_many("SELECT COUNT(*) FROM shell_commands WHERE session_id = ? AND status = 'pending'", [session_id]) or {
		store.db.rollback() or {}
		return error('unable to inspect pending shell commands')
	}
	if pending.len != 1 || pending[0].val(0).int() >= max_pending_shell_commands {
		store.db.rollback() or {}
		return error('pending shell command limit reached')
	}
	id := uuid.new_v4().str()
	_ = store.db.exec_param_many('INSERT INTO shell_commands (id, session_id, command, cwd, timeout_seconds, status) VALUES (?, ?, ?, ?, ?, ?)', [
		id,
		session_id,
		draft.command,
		draft.cwd,
		draft.timeout_seconds.str(),
		'pending',
	]) or {
		store.db.rollback() or {}
		return error('unable to persist shell command proposal')
	}
	_ = store.db.exec_param_many('INSERT INTO events (type, session_id) VALUES (?, ?)', [
		'shell.command_proposed',
		session_id,
	]) or {
		store.db.rollback() or {}
		return error('unable to record shell command proposal')
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit shell command proposal')
	}
	return store.get_shell_command_unlocked(session_id, id)!
}

fn (mut store Store) shell_commands(session_id string) ![]ShellCommandSummary {
	store.mu.lock()
	defer { store.mu.unlock() }
	rows := store.db.exec_param_many("SELECT id, command, cwd, timeout_seconds, status, exit_code, '', created_at, updated_at FROM shell_commands WHERE session_id = ? ORDER BY created_at DESC, id DESC LIMIT 50", [session_id])!
	mut commands := []ShellCommandSummary{cap: rows.len}
	for row in rows { commands << shell_command_from_row(row, '') }
	return commands
}

fn (mut store Store) review_shell_command(session_id string, id string) !ShellCommandSummary {
	store.mu.lock()
	defer { store.mu.unlock() }
	store.db.begin()!
	rows := store.db.exec_param_many("SELECT id, command, cwd, timeout_seconds, status, exit_code, output, created_at, updated_at, COALESCE(reviewed_at, '') FROM shell_commands WHERE session_id = ? AND id = ?", [
		session_id,
		id,
	]) or {
		store.db.rollback() or {}
		return error('unable to read shell command')
	}
	if rows.len != 1 {
		store.db.rollback() or {}
		return error('shell command not found')
	}
	row := rows[0]
	if row.val(4) == 'pending' && row.val(9).len == 0 {
		_ = store.db.exec_param_many("UPDATE shell_commands SET reviewed_at = CURRENT_TIMESTAMP WHERE id = ? AND session_id = ? AND status = 'pending' AND reviewed_at IS NULL", [
			id,
			session_id,
		]) or {
			store.db.rollback() or {}
			return error('unable to record shell command review')
		}
		if store.db.get_affected_rows_count() != 1 {
			store.db.rollback() or {}
			return error('shell command changed while being reviewed')
		}
		_ = store.db.exec_param_many('INSERT INTO events (type, session_id) VALUES (?, ?)', [
			'shell.command_reviewed',
			session_id,
		]) or {
			store.db.rollback() or {}
			return error('unable to record shell command review event')
		}
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit shell command review')
	}
	return shell_command_from_row(row, '')
}

fn (mut store Store) begin_shell_command(session_id string, id string) !ShellCommandSummary {
	store.mu.lock()
	defer { store.mu.unlock() }
	store.db.begin()!
	rows := store.db.exec_param_many("SELECT id, command, cwd, timeout_seconds, status, exit_code, output, created_at, updated_at, COALESCE(reviewed_at, '') FROM shell_commands WHERE session_id = ? AND id = ?", [
		session_id,
		id,
	]) or {
		store.db.rollback() or {}
		return error('unable to read shell command')
	}
	if rows.len != 1 || rows[0].val(4) != 'pending' || rows[0].val(9).len == 0 {
		store.db.rollback() or {}
		return error('shell command has not been reviewed and is awaiting approval')
	}
	row := rows[0]
	_ = store.db.exec_param_many("UPDATE shell_commands SET status = 'running', updated_at = CURRENT_TIMESTAMP WHERE id = ? AND session_id = ? AND status = 'pending' AND reviewed_at IS NOT NULL", [
		id,
		session_id,
	]) or {
		store.db.rollback() or {}
		return error('unable to persist shell command approval')
	}
	if store.db.get_affected_rows_count() != 1 {
		store.db.rollback() or {}
		return error('shell command is no longer awaiting approval')
	}
	_ = store.db.exec_param_many('INSERT INTO events (type, session_id) VALUES (?, ?)', [
		'shell.command_approved',
		session_id,
	]) or {
		store.db.rollback() or {}
		return error('unable to record shell command approval')
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit shell command approval')
	}
	return shell_command_from_row(row, 'running')
}

fn (mut store Store) finish_shell_command(session_id string, id string, result ShellCommandResult) ! {
	store.mu.lock()
	defer { store.mu.unlock() }
	store.db.begin()!
	_ = store.db.exec_param_many('UPDATE shell_commands SET status = ?, exit_code = ?, output = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND session_id = ? AND status = ?', [
		result.status,
		result.exit_code.str(),
		result.output,
		id,
		session_id,
		'running',
	]) or {
		store.db.rollback() or {}
		return error('unable to persist shell command result')
	}
	if store.db.get_affected_rows_count() != 1 {
		store.db.rollback() or {}
		return error('shell command state changed unexpectedly')
	}
	_ = store.db.exec_param_many('INSERT INTO events (type, session_id) VALUES (?, ?)', [
		'shell.command_${result.status}',
		session_id,
	]) or {
		store.db.rollback() or {}
		return error('unable to record shell command result')
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit shell command result')
	}
}

fn (mut store Store) reject_shell_command(session_id string, id string) ! {
	store.mu.lock()
	defer { store.mu.unlock() }
	store.db.begin()!
	_ = store.db.exec_param_many("UPDATE shell_commands SET status = 'rejected', updated_at = CURRENT_TIMESTAMP WHERE id = ? AND session_id = ? AND status = 'pending'", [
		id,
		session_id,
	]) or {
		store.db.rollback() or {}
		return error('unable to reject shell command')
	}
	if store.db.get_affected_rows_count() != 1 {
		store.db.rollback() or {}
		return error('shell command is not awaiting review')
	}
	_ = store.db.exec_param_many('INSERT INTO events (type, session_id) VALUES (?, ?)', [
		'shell.command_rejected',
		session_id,
	]) or {
		store.db.rollback() or {}
		return error('unable to record shell command rejection')
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit shell command rejection')
	}
}

fn (mut store Store) get_shell_command_unlocked(session_id string, id string) !ShellCommandSummary {
	rows := store.db.exec_param_many('SELECT id, command, cwd, timeout_seconds, status, exit_code, output, created_at, updated_at FROM shell_commands WHERE session_id = ? AND id = ?', [
		session_id,
		id,
	])!
	if rows.len != 1 { return error('shell command not found') }
	return shell_command_from_row(rows[0], '')
}

fn shell_command_from_row(row sqlite.Row, status_override string) ShellCommandSummary {
	return ShellCommandSummary{
		id:              row.val(0)
		command:         row.val(1)
		cwd:             row.val(2)
		timeout_seconds: row.val(3).int()
		status:          if status_override.len > 0 {
			status_override
		} else {
			row.val(4)
		}
		exit_code:       row.val(5).int()
		output:          row.val(6)
		created_at:      row.val(7)
		updated_at:      row.val(8)
	}
}

fn (mut store Store) session_plugin_skills(session_id string) ![]SessionPluginSkill {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	rows := store.db.exec_param('SELECT plugin_name, skill_name FROM session_plugin_skills WHERE session_id = ? ORDER BY plugin_name, skill_name',
		session_id)!
	mut skills := []SessionPluginSkill{cap: rows.len}
	for row in rows {
		skills << SessionPluginSkill{
			plugin_name: row.val(0)
			skill_name:  row.val(1)
		}
	}
	return skills
}

fn (mut store Store) set_session_plugin_skill(session_id string, plugin_name string, skill_name string, enabled bool) ! {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	store.db.begin()!
	rows := store.db.exec_param_many('SELECT 1 FROM session_plugin_skills WHERE session_id = ? AND plugin_name = ? AND skill_name = ?',
		[session_id, plugin_name, skill_name]) or {
		store.db.rollback() or {}
		return error('unable to read session plugin skills')
	}
	exists := rows.len != 0
	if exists == enabled {
		store.db.commit() or {
			store.db.rollback() or {}
			return error('unable to commit session plugin skill update')
		}
		return
	}
	if enabled {
		_ = store.db.exec_param_many('INSERT INTO session_plugin_skills (session_id, plugin_name, skill_name) VALUES (?, ?, ?)',
			[session_id, plugin_name, skill_name]) or {
			store.db.rollback() or {}
			return error('unable to enable session plugin skill')
		}
	} else {
		_ = store.db.exec_param_many('DELETE FROM session_plugin_skills WHERE session_id = ? AND plugin_name = ? AND skill_name = ?',
			[session_id, plugin_name, skill_name]) or {
			store.db.rollback() or {}
			return error('unable to disable session plugin skill')
		}
	}
	event_type := if enabled { 'session.skill_enabled' } else { 'session.skill_disabled' }
	_ = store.db.exec_param_many('INSERT INTO events (type, session_id) VALUES (?, ?)',
		[event_type, session_id]) or {
		store.db.rollback() or {}
		return error('unable to record session plugin skill event')
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit session plugin skill update')
	}
}

fn (mut store Store) session_plugin_mcp_servers(session_id string) ![]SessionPluginMCPServer {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	rows := store.db.exec_param('SELECT plugin_name, server_name FROM session_plugin_mcp_servers WHERE session_id = ? ORDER BY plugin_name, server_name',
		session_id)!
	mut servers := []SessionPluginMCPServer{cap: rows.len}
	for row in rows {
		servers << SessionPluginMCPServer{
			plugin_name: row.val(0)
			server_name: row.val(1)
		}
	}
	return servers
}

fn (mut store Store) set_session_plugin_mcp_server(session_id string, plugin_name string,
	server_name string, trusted bool) ! {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	store.db.begin()!
	rows := store.db.exec_param_many('SELECT 1 FROM session_plugin_mcp_servers WHERE session_id = ? AND plugin_name = ? AND server_name = ?',
		[session_id, plugin_name, server_name]) or {
		store.db.rollback() or {}
		return error('unable to read session plugin MCP trust')
	}
	exists := rows.len != 0
	if exists == trusted {
		store.db.commit() or {
			store.db.rollback() or {}
			return error('unable to commit session plugin MCP trust update')
		}
		return
	}
	if trusted {
		_ = store.db.exec_param_many('INSERT INTO session_plugin_mcp_servers (session_id, plugin_name, server_name) VALUES (?, ?, ?)',
			[session_id, plugin_name, server_name]) or {
			store.db.rollback() or {}
			return error('unable to trust session plugin MCP server')
		}
	} else {
		_ = store.db.exec_param_many('DELETE FROM session_plugin_mcp_servers WHERE session_id = ? AND plugin_name = ? AND server_name = ?',
			[session_id, plugin_name, server_name]) or {
			store.db.rollback() or {}
			return error('unable to revoke session plugin MCP trust')
		}
	}
	event_type := if trusted {
		'session.mcp_server_trusted'
	} else {
		'session.mcp_server_untrusted'
	}
	_ = store.db.exec_param_many('INSERT INTO events (type, session_id) VALUES (?, ?)',
		[event_type, session_id]) or {
		store.db.rollback() or {}
		return error('unable to record session plugin MCP trust event')
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit session plugin MCP trust update')
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

fn (mut store Store) create_workspace_edit(session_id string, draft WorkspaceEditDraft) !WorkspaceEditProposal {
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
	pending := store.db.exec_param("SELECT COUNT(*) FROM workspace_edits WHERE session_id = ? AND status = 'pending'",
		session_id) or {
		store.db.rollback() or {}
		return error('unable to inspect pending workspace edits')
	}
	if pending.len != 1 || pending[0].val(0).int() >= max_pending_workspace_edits {
		store.db.rollback() or {}
		return error('pending workspace edit limit reached')
	}
	id := uuid.new_v4().str()
	_ = store.db.exec_param_many('INSERT INTO workspace_edits (id, session_id, path, expected_hash, content, diff, create_file, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
		[id, session_id, draft.path, draft.expected_hash, draft.content, draft.diff, if draft.create_file {
			'1'
		} else {
			'0'
		}, 'pending']) or {
		store.db.rollback() or {}
		return error('unable to persist workspace edit proposal')
	}
	_ = store.db.exec_param_many('INSERT INTO events (type, session_id) VALUES (?, ?)',
		['workspace.edit_proposed', session_id]) or {
		store.db.rollback() or {}
		return error('unable to record workspace edit proposal')
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit workspace edit proposal')
	}
	rows := store.db.exec_param('SELECT id, session_id, path, diff, status, created_at, updated_at FROM workspace_edits WHERE id = ?',
		id)!
	if rows.len != 1 {
		return error('workspace edit proposal could not be read')
	}
	return workspace_edit_proposal_from_row(rows[0])
}

fn (mut store Store) workspace_edits(session_id string) ![]WorkspaceEditSummary {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	rows := store.db.exec_param_many('SELECT id, path, status, created_at, updated_at FROM workspace_edits WHERE session_id = ? ORDER BY created_at DESC, id DESC LIMIT 50',
		[session_id])!
	mut proposals := []WorkspaceEditSummary{cap: rows.len}
	for row in rows {
		proposals << WorkspaceEditSummary{
			id:         row.val(0)
			path:       row.val(1)
			status:     row.val(2)
			created_at: row.val(3)
			updated_at: row.val(4)
		}
	}
	return proposals
}

fn (mut store Store) review_workspace_edit(session_id string, id string) !WorkspaceEditProposal {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	store.db.begin()!
	rows := store.db.exec_param_many("SELECT id, session_id, path, diff, status, created_at, updated_at, COALESCE(reviewed_at, '') FROM workspace_edits WHERE session_id = ? AND id = ?",
		[session_id, id]) or {
		store.db.rollback() or {}
		return error('unable to read workspace edit proposal')
	}
	if rows.len != 1 {
		store.db.rollback() or {}
		return error('workspace edit proposal not found')
	}
	row := rows[0]
	proposal := workspace_edit_proposal_from_row(row)
	if row.val(4) == 'pending' && row.val(7).len == 0 {
		_ = store.db.exec_param_many("UPDATE workspace_edits SET reviewed_at = CURRENT_TIMESTAMP WHERE id = ? AND session_id = ? AND status = 'pending' AND reviewed_at IS NULL",
			[id, session_id]) or {
			store.db.rollback() or {}
			return error('unable to record workspace edit review')
		}
		if store.db.get_affected_rows_count() != 1 {
			store.db.rollback() or {}
			return error('workspace edit changed while it was being reviewed')
		}
		_ = store.db.exec_param_many('INSERT INTO events (type, session_id) VALUES (?, ?)',
			['workspace.edit_reviewed', session_id]) or {
			store.db.rollback() or {}
			return error('unable to record workspace edit review event')
		}
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit workspace edit review')
	}
	return proposal
}

fn (mut store Store) begin_workspace_edit(session_id string, id string) !StoredWorkspaceEdit {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	store.db.begin()!
	rows := store.db.exec_param_many("SELECT id, session_id, path, expected_hash, content, diff, create_file, status, COALESCE(reviewed_at, '') FROM workspace_edits WHERE id = ? AND session_id = ?",
		[id, session_id]) or {
		store.db.rollback() or {}
		return error('unable to read workspace edit proposal')
	}
	if rows.len != 1 || rows[0].val(7) != 'pending' {
		store.db.rollback() or {}
		return error('workspace edit is not awaiting approval')
	}
	row := rows[0]
	if row.val(8).len == 0 {
		store.db.rollback() or {}
		return error('workspace edit diff has not been reviewed')
	}
	edit := StoredWorkspaceEdit{
		id:            row.val(0)
		session_id:    row.val(1)
		path:          row.val(2)
		expected_hash: row.val(3)
		content:       row.val(4)
		diff:          row.val(5)
		create_file:   row.val(6).int() == 1
		status:        'applying'
	}
	_ = store.db.exec_param_many("UPDATE workspace_edits SET status = 'applying', updated_at = CURRENT_TIMESTAMP WHERE id = ? AND session_id = ? AND status = 'pending' AND reviewed_at IS NOT NULL",
		[id, session_id]) or {
		store.db.rollback() or {}
		return error('unable to record workspace edit approval')
	}
	if store.db.get_affected_rows_count() != 1 {
		store.db.rollback() or {}
		return error('workspace edit is not awaiting approval')
	}
	_ = store.db.exec_param_many('INSERT INTO events (type, session_id) VALUES (?, ?)',
		['workspace.edit_approved', session_id]) or {
		store.db.rollback() or {}
		return error('unable to record workspace edit approval event')
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit workspace edit approval')
	}
	return edit
}

fn (mut store Store) finish_workspace_edit(session_id string, id string, status string) ! {
	if status !in ['applied', 'conflict', 'interrupted'] {
		return error('invalid workspace edit state transition')
	}
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	store.db.begin()!
	_ = store.db.exec_param_many('UPDATE workspace_edits SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND session_id = ? AND status = ?',
		[status, id, session_id, 'applying']) or {
		store.db.rollback() or {}
		return error('unable to update workspace edit state')
	}
	if store.db.get_affected_rows_count() != 1 {
		store.db.rollback() or {}
		return error('workspace edit state changed unexpectedly')
	}
	rows := store.db.exec_param_many('SELECT status FROM workspace_edits WHERE id = ? AND session_id = ?',
		[id, session_id]) or {
		store.db.rollback() or {}
		return error('unable to verify workspace edit state')
	}
	if rows.len != 1 || rows[0].val(0) != status {
		store.db.rollback() or {}
		return error('workspace edit state changed unexpectedly')
	}
	event_type := match status {
		'applied' { 'workspace.edit_applied' }
		'conflict' { 'workspace.edit_conflict' }
		else { 'workspace.edit_interrupted' }
	}
	_ = store.db.exec_param_many('INSERT INTO events (type, session_id) VALUES (?, ?)',
		[event_type, session_id]) or {
		store.db.rollback() or {}
		return error('unable to record workspace edit state')
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit workspace edit state')
	}
}

fn (mut store Store) reject_workspace_edit(session_id string, id string) ! {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	store.db.begin()!
	_ = store.db.exec_param_many("UPDATE workspace_edits SET status = 'rejected', updated_at = CURRENT_TIMESTAMP WHERE id = ? AND session_id = ? AND status = 'pending'",
		[id, session_id]) or {
		store.db.rollback() or {}
		return error('unable to reject workspace edit')
	}
	if store.db.get_affected_rows_count() != 1 {
		store.db.rollback() or {}
		return error('workspace edit is not awaiting review')
	}
	rows := store.db.exec_param_many('SELECT status FROM workspace_edits WHERE id = ? AND session_id = ?',
		[id, session_id]) or {
		store.db.rollback() or {}
		return error('unable to verify workspace edit status')
	}
	if rows.len != 1 || rows[0].val(0) != 'rejected' {
		store.db.rollback() or {}
		return error('workspace edit is not awaiting review')
	}
	_ = store.db.exec_param_many('INSERT INTO events (type, session_id) VALUES (?, ?)',
		['workspace.edit_rejected', session_id]) or {
		store.db.rollback() or {}
		return error('unable to record workspace edit rejection')
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit workspace edit rejection')
	}
}

fn workspace_edit_proposal_from_row(row sqlite.Row) WorkspaceEditProposal {
	return WorkspaceEditProposal{
		id:         row.val(0)
		session_id: row.val(1)
		path:       row.val(2)
		diff:       row.val(3)
		status:     row.val(4)
		created_at: row.val(5)
		updated_at: row.val(6)
	}
}
