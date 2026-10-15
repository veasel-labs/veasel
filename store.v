module main

import db.sqlite
import json2
import os
import strings
import sync
import uuid

const max_session_history_page_size = 100
const max_event_stream_page_size = 500
const max_retained_terminal_session_operations = 200
const max_retained_session_events = 5_000
const max_queued_session_operations_per_session = 32

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

pub struct SessionOperation {
pub:
	id                    string
	session_id            string
	status                string
	provider              string
	model                 string
	error                 string
	input_tokens          i64  @[omitempty]
	output_tokens         i64  @[omitempty]
	usage_reported        bool @[omitempty]
	cache_read_tokens     i64  @[omitempty]
	cache_creation_tokens i64  @[omitempty]
	cache_reported        bool @[omitempty]
	reasoning_tokens      i64  @[omitempty]
	reasoning_reported    bool @[omitempty]
	created_at            string
	updated_at            string
}

// SessionUsageSummary aggregates adapter-reported tokens for one session.
// Cost is never estimated here. Cache and reasoning counters are provider-reported only.
pub struct SessionUsageSummary {
pub:
	session_id            string
	completed_turns       int
	reported_turns        int
	input_tokens          i64
	output_tokens         i64
	usage_reported        bool
	cache_read_tokens     i64
	cache_creation_tokens i64
	cache_reported        bool
	reasoning_tokens      i64
	reasoning_reported    bool
	cost                  string = 'unavailable'
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
	data       EventData
}

struct EventData {
pub:
	operation_id                   string @[omitempty]
	delta                          string @[omitempty]
	status                         string @[omitempty]
	provider                       string @[omitempty]
	model                          string @[omitempty]
	error                          string @[omitempty]
	input_tokens                   i64    @[omitempty]
	output_tokens                  i64    @[omitempty]
	usage_reported                 bool   @[omitempty]
	cache_read_tokens              i64    @[omitempty]
	cache_creation_tokens          i64    @[omitempty]
	cache_reported                 bool   @[omitempty]
	reasoning_tokens               i64    @[omitempty]
	reasoning_reported             bool   @[omitempty]
	compaction_bytes_before        int    @[omitempty]
	compaction_bytes_after         int    @[omitempty]
	compaction_token_bound_before  int    @[omitempty]
	compaction_token_bound_after   int    @[omitempty]
	compaction_summarized_messages int    @[omitempty]
	compaction_kept_messages       int    @[omitempty]
	compaction_reason              string @[omitempty]
	compaction_untrusted           bool   @[omitempty]
	compaction_summary_preview     string @[omitempty]
	compaction_summarizer_mode     string @[omitempty]
	compaction_usage_reported      bool   @[omitempty]
	compaction_input_tokens        i64    @[omitempty]
	compaction_output_tokens       i64    @[omitempty]
	repository_map_bytes           int    @[omitempty]
	repository_map_token_bound     int    @[omitempty]
	repository_map_budget_bytes    int    @[omitempty]
	repository_map_file_count      int    @[omitempty]
	repository_map_symbol_count    int    @[omitempty]
	repository_map_truncated       bool   @[omitempty]
	repository_map_injected        bool   @[omitempty]
	repository_map_untrusted       bool   @[omitempty]
	repository_map_preview         string @[omitempty]
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
	mu   sync.Mutex
	db   sqlite.DB
	path string
	// When > 0, overrides max_retained_terminal_session_operations (tests only).
	terminal_ops_retention_limit int
	// When > 0, overrides max_retained_session_events (tests only).
	session_events_retention_limit int
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
	// NORMAL with WAL is the usual durable+fast setting; FULL (default) fsyncs
	// more aggressively than agent-session write patterns need.
	db.synchronization_mode(.normal) or {
		db.close() or {}
		return error('unable to configure SQLite synchronous mode')
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
	if current < 7 {
		db.begin() or {
			db.close() or {}
			return error('unable to begin streaming event migration')
		}
		db.exec("ALTER TABLE events ADD COLUMN data TEXT NOT NULL DEFAULT '{}'") or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to add streaming event data')
		}
		db.exec('INSERT INTO schema_migrations (version) VALUES (7)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to record streaming event migration')
		}
		db.commit() or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to commit streaming event migration')
		}
	}
	if current < 8 {
		db.begin() or {
			db.close() or {}
			return error('unable to begin MCP tool approval migration')
		}
		db.exec("CREATE TABLE plugin_mcp_tool_calls (id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, operation_id TEXT NOT NULL, plugin_name TEXT NOT NULL, server_name TEXT NOT NULL, tool_name TEXT NOT NULL, arguments TEXT NOT NULL, status TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'running', 'completed', 'rejected', 'failed', 'cancelled', 'uncertain')), reviewed_at TEXT, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)") or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to create MCP tool approval table')
		}
		db.exec('CREATE INDEX plugin_mcp_tool_calls_session_created ON plugin_mcp_tool_calls (session_id, created_at, id)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to index MCP tool approvals')
		}
		db.exec('INSERT INTO schema_migrations (version) VALUES (8)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to record MCP tool approval migration')
		}
		db.commit() or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to commit MCP tool approval migration')
		}
	}
	if current < 9 {
		db.begin() or {
			db.close() or {}
			return error('unable to begin durable operation migration')
		}
		db.exec("CREATE TABLE session_operations (id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, status TEXT NOT NULL CHECK (status IN ('running', 'cancelling', 'completed', 'failed', 'cancelled', 'uncertain')), provider TEXT NOT NULL DEFAULT '', model TEXT NOT NULL DEFAULT '', error TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)") or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to create session operation table')
		}
		db.exec('CREATE INDEX session_operations_session_created ON session_operations (session_id, created_at, id)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to index session operations')
		}
		db.exec('INSERT INTO schema_migrations (version) VALUES (9)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to record durable operation migration')
		}
		db.commit() or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to commit durable operation migration')
		}
	}
	if current < 10 {
		db.begin() or {
			db.close() or {}
			return error('unable to begin event lookup index migration')
		}
		db.exec('CREATE INDEX events_session_type_id ON events (session_id, type, id)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to index session event lookups')
		}
		db.exec('INSERT INTO schema_migrations (version) VALUES (10)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to record event lookup index migration')
		}
		db.commit() or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to commit event lookup index migration')
		}
	}
	if current < 11 {
		db.begin() or {
			db.close() or {}
			return error('unable to begin operation trace migration')
		}
		db.exec('CREATE TABLE operation_traces (operation_id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, trajectory_json TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to create operation trace table')
		}
		db.exec('INSERT INTO schema_migrations (version) VALUES (11)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to record operation trace migration')
		}
		db.commit() or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to commit operation trace migration')
		}
	}
	if current < 12 {
		db.begin() or {
			db.close() or {}
			return error('unable to begin operation usage migration')
		}
		// Provider-reported token totals only. Cost stays unavailable until Veasel
		// pins authoritative price schedules; never invent estimates here.
		db.exec('ALTER TABLE session_operations ADD COLUMN input_tokens INTEGER NOT NULL DEFAULT 0') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to add operation input token column')
		}
		db.exec('ALTER TABLE session_operations ADD COLUMN output_tokens INTEGER NOT NULL DEFAULT 0') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to add operation output token column')
		}
		db.exec('ALTER TABLE session_operations ADD COLUMN usage_reported INTEGER NOT NULL DEFAULT 0 CHECK (usage_reported IN (0, 1))') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to add operation usage flag column')
		}
		db.exec('INSERT INTO schema_migrations (version) VALUES (12)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to record operation usage migration')
		}
		db.commit() or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to commit operation usage migration')
		}
	}
	if current < 13 {
		db.begin() or {
			db.close() or {}
			return error('unable to begin durable queue migration')
		}
		// Rebuild so CHECK accepts queued and request_json survives restarts for
		// jobs that never claimed a worker. Running work still fails closed.
		db.exec("CREATE TABLE session_operations_v13 (id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, status TEXT NOT NULL CHECK (status IN ('queued', 'running', 'cancelling', 'completed', 'failed', 'cancelled', 'uncertain')), provider TEXT NOT NULL DEFAULT '', model TEXT NOT NULL DEFAULT '', error TEXT NOT NULL DEFAULT '', request_json TEXT NOT NULL DEFAULT '', input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0, usage_reported INTEGER NOT NULL DEFAULT 0 CHECK (usage_reported IN (0, 1)), created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)") or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to create durable queue operation table')
		}
		db.exec("INSERT INTO session_operations_v13 (id, session_id, status, provider, model, error, request_json, input_tokens, output_tokens, usage_reported, created_at, updated_at) SELECT id, session_id, status, provider, model, error, '', input_tokens, output_tokens, usage_reported, created_at, updated_at FROM session_operations") or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to copy session operations for durable queue')
		}
		db.exec('DROP TABLE session_operations') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to replace session operations table')
		}
		db.exec('ALTER TABLE session_operations_v13 RENAME TO session_operations') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to rename durable queue operation table')
		}
		db.exec('CREATE INDEX session_operations_session_created ON session_operations (session_id, created_at, id)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to index session operations after durable queue migration')
		}
		db.exec('CREATE INDEX session_operations_status_created ON session_operations (status, created_at, id)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to index queued session operations')
		}
		db.exec('INSERT INTO schema_migrations (version) VALUES (13)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to record durable queue migration')
		}
		db.commit() or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to commit durable queue migration')
		}
	}
	if current < 14 {
		db.begin() or {
			db.close() or {}
			return error('unable to begin prompt-cache usage migration')
		}
		// Provider-reported cache counters only. Absent keys stay unreported;
		// never invent cache hits or savings percentages.
		db.exec('ALTER TABLE session_operations ADD COLUMN cache_read_tokens INTEGER NOT NULL DEFAULT 0') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to add operation cache read token column')
		}
		db.exec('ALTER TABLE session_operations ADD COLUMN cache_creation_tokens INTEGER NOT NULL DEFAULT 0') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to add operation cache creation token column')
		}
		db.exec('ALTER TABLE session_operations ADD COLUMN cache_reported INTEGER NOT NULL DEFAULT 0 CHECK (cache_reported IN (0, 1))') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to add operation cache usage flag column')
		}
		db.exec('INSERT INTO schema_migrations (version) VALUES (14)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to record prompt-cache usage migration')
		}
		db.commit() or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to commit prompt-cache usage migration')
		}
	}
	if current < 15 {
		db.begin() or {
			db.close() or {}
			return error('unable to begin reasoning usage migration')
		}
		// Provider-reported reasoning/thinking counters only. Absent keys stay
		// unreported; never invent reasoning tokens.
		db.exec('ALTER TABLE session_operations ADD COLUMN reasoning_tokens INTEGER NOT NULL DEFAULT 0') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to add operation reasoning token column')
		}
		db.exec('ALTER TABLE session_operations ADD COLUMN reasoning_reported INTEGER NOT NULL DEFAULT 0 CHECK (reasoning_reported IN (0, 1))') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to add operation reasoning usage flag column')
		}
		db.exec('INSERT INTO schema_migrations (version) VALUES (15)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to record reasoning usage migration')
		}
		db.commit() or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to commit reasoning usage migration')
		}
	}
	if current < 16 {
		db.begin() or {
			db.close() or {}
			return error('unable to begin session skill invoke migration')
		}
		db.exec('CREATE TABLE session_skill_invokes (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, plugin_name TEXT NOT NULL, skill_name TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to create session skill invoke table')
		}
		db.exec('CREATE INDEX session_skill_invokes_session_id ON session_skill_invokes (session_id, id)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to index session skill invokes')
		}
		db.exec('INSERT INTO schema_migrations (version) VALUES (16)') or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to record session skill invoke migration')
		}
		db.commit() or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to commit session skill invoke migration')
		}
	}
	// Running or cancelling work may have contacted a provider or started a tool
	// effect without a durable result, so it becomes uncertain and is never
	// replayed. Queued jobs never claimed a worker; their request_json is kept
	// for honest resume after restart.
	db.begin() or {
		db.close() or {}
		return error('unable to begin session operation recovery')
	}
	interrupted_operations := db.exec("SELECT id, session_id FROM session_operations WHERE status IN ('running', 'cancelling')") or {
		db.rollback() or {}
		db.close() or {}
		return error('unable to inspect interrupted session operations')
	}
	for row in interrupted_operations {
		_ = db.exec_param_many("UPDATE session_operations SET status = 'uncertain', error = 'The server stopped before this operation reached a recorded result.', updated_at = CURRENT_TIMESTAMP WHERE id = ? AND status IN ('running', 'cancelling')", [row.val(0)]) or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to classify interrupted session operation')
		}
		_ = db.exec_param_many('INSERT INTO events (type, session_id, data) VALUES (?, ?, ?)', [
			'session.turn_completed',
			row.val(1),
			json2.encode[EventData](EventData{
				operation_id: row.val(0)
				status:       'uncertain'
				error:        'The server stopped before this operation reached a recorded result.'
			}),
		]) or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to record interrupted session operation')
		}
	}
	db.commit() or {
		db.rollback() or {}
		db.close() or {}
		return error('unable to commit session operation recovery')
	}
	db.begin() or {
		db.close() or {}
		return error('unable to begin MCP tool approval recovery')
	}
	interrupted_calls := db.exec("SELECT id, session_id, status FROM plugin_mcp_tool_calls WHERE status IN ('pending', 'approved', 'running')") or {
		db.rollback() or {}
		db.close() or {}
		return error('unable to inspect interrupted MCP tool calls')
	}
	for row in interrupted_calls {
		status := if row.val(2) == 'running' { 'uncertain' } else { 'cancelled' }
		_ = db.exec_param_many('UPDATE plugin_mcp_tool_calls SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND status = ?', [
			status,
			row.val(0),
			row.val(2),
		]) or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to recover interrupted MCP tool call')
		}
		_ = db.exec_param_many('INSERT INTO events (type, session_id) VALUES (?, ?)', [
			'plugin.mcp_tool_call_${status}',
			row.val(1),
		]) or {
			db.rollback() or {}
			db.close() or {}
			return error('unable to record MCP tool call recovery')
		}
	}
	db.commit() or {
		db.rollback() or {}
		db.close() or {}
		return error('unable to commit MCP tool approval recovery')
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
		db:   db
		path: path
	}
}

fn (store &Store) model_settings_path() string {
	if store.path == ':memory:' {
		return ''
	}
	return os.join_path(os.dir(store.path), 'model-settings.json')
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

const max_session_skill_invokes = 8

fn (mut store Store) enqueue_session_skill_invoke(session_id string, plugin_name string, skill_name string) ![]SessionPluginSkill {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	store.db.begin()!
	pending := store.db.exec_param('SELECT COUNT(*) FROM session_skill_invokes WHERE session_id = ?',
		session_id) or {
		store.db.rollback() or {}
		return error('unable to count session skill invokes')
	}
	count := if pending.len > 0 { pending[0].val(0).int() } else { 0 }
	if count >= max_session_skill_invokes {
		store.db.rollback() or {}
		return error('A session can queue at most ${max_session_skill_invokes} one-shot skill invokes')
	}
	_ = store.db.exec_param_many('INSERT INTO session_skill_invokes (session_id, plugin_name, skill_name) VALUES (?, ?, ?)',
		[session_id, plugin_name, skill_name]) or {
		store.db.rollback() or {}
		return error('unable to enqueue session skill invoke')
	}
	_ = store.db.exec_param_many('INSERT INTO events (type, session_id) VALUES (?, ?)',
		['session.skill_invoked', session_id]) or {
		store.db.rollback() or {}
		return error('unable to record session skill invoke event')
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit session skill invoke')
	}
	rows := store.db.exec_param('SELECT plugin_name, skill_name FROM session_skill_invokes WHERE session_id = ? ORDER BY id',
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

// take_session_skill_invokes returns and clears pending one-shot skill invokes
// so they inject into the next turn only.
fn (mut store Store) take_session_skill_invokes(session_id string) ![]SessionPluginSkill {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	store.db.begin()!
	rows := store.db.exec_param('SELECT plugin_name, skill_name FROM session_skill_invokes WHERE session_id = ? ORDER BY id',
		session_id) or {
		store.db.rollback() or {}
		return error('unable to read session skill invokes')
	}
	mut skills := []SessionPluginSkill{cap: rows.len}
	for row in rows {
		skills << SessionPluginSkill{
			plugin_name: row.val(0)
			skill_name:  row.val(1)
		}
	}
	if skills.len > 0 {
		_ = store.db.exec_param('DELETE FROM session_skill_invokes WHERE session_id = ?', session_id) or {
			store.db.rollback() or {}
			return error('unable to clear session skill invokes')
		}
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit session skill invoke take')
	}
	return skills
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

fn (mut store Store) create_session_operation(session_id string, operation_id string) !SessionOperation {
	// Test and recovery helpers create an already-claimed running row. Prefer
	// enqueue_session_operation for durable Prefer: respond-async turns.
	return store.insert_session_operation(session_id, operation_id, 'running', '', 'session.turn_started')
}

fn (mut store Store) enqueue_session_operation(session_id string, operation_id string,
	request_json string) !SessionOperation {
	if request_json.trim_space().len == 0 {
		return error('queued session operation requires a request payload')
	}
	if request_json.contains('\0') {
		return error('queued session operation request is invalid')
	}
	if request_json.len > max_chat_input_bytes + 2048 {
		return error('queued session operation request exceeds the size limit')
	}
	input := json2.decode[ChatMessageInput](request_json) or {
		return error('queued session operation request is invalid')
	}
	validate_messages([
		ChatMessage{
			role:    'user'
			content: input.content
		},
	]) or { return error('queued session operation request is invalid') }
	return store.insert_session_operation(session_id, operation_id, 'queued', request_json,
		'session.turn_queued')
}

fn (mut store Store) insert_session_operation(session_id string, operation_id string, status string,
	request_json string, event_type string) !SessionOperation {
	if !validate_operation_id(operation_id) {
		return error('invalid session operation identifier')
	}
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	store.db.begin()!
	existing := store.db.exec_param_many('SELECT id FROM session_operations WHERE id = ?', [operation_id]) or {
		store.db.rollback() or {}
		return error('unable to check session operation identifier')
	}
	if existing.len > 0 {
		store.db.rollback() or {}
		return error('session operation already exists')
	}
	if status == 'queued' {
		queued_rows := store.db.exec_param("SELECT COUNT(*) FROM session_operations WHERE session_id = ? AND status = 'queued'",
			session_id) or {
			store.db.rollback() or {}
			return error('unable to count queued session operations')
		}
		if queued_rows.len == 1 && queued_rows[0].val(0).int() >= max_queued_session_operations_per_session {
			store.db.rollback() or {}
			return error('queued_operations_full')
		}
	}
	_ = store.db.exec_param_many('INSERT INTO session_operations (id, session_id, status, request_json) VALUES (?, ?, ?, ?)', [
		operation_id,
		session_id,
		status,
		request_json,
	]) or {
		store.db.rollback() or {}
		return error('unable to persist session operation')
	}
	_ = store.db.exec_param_many('INSERT INTO events (type, session_id, data) VALUES (?, ?, ?)', [
		event_type,
		session_id,
		json2.encode[EventData](EventData{
			operation_id: operation_id
			status:       status
		}),
	]) or {
		store.db.rollback() or {}
		return error('unable to persist session operation event')
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit session operation')
	}
	return store.session_operation_unlocked(session_id, operation_id)
}

fn (mut store Store) claim_session_operation(session_id string, operation_id string) !SessionOperation {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	store.db.begin()!
	updated := store.db.exec_param_many("UPDATE session_operations SET status = 'running', updated_at = CURRENT_TIMESTAMP WHERE session_id = ? AND id = ? AND status = 'queued'",
		[session_id, operation_id]) or {
		store.db.rollback() or {}
		return error('unable to claim session operation')
	}
	_ = updated
	rows := store.db.exec_param_many('SELECT status FROM session_operations WHERE session_id = ? AND id = ?',
		[session_id, operation_id]) or {
		store.db.rollback() or {}
		return error('unable to read claimed session operation')
	}
	if rows.len != 1 {
		store.db.rollback() or {}
		return error('session operation not found')
	}
	if rows[0].val(0) != 'running' {
		store.db.rollback() or {}
		return error('session operation is ${rows[0].val(0)}')
	}
	_ = store.db.exec_param_many('INSERT INTO events (type, session_id, data) VALUES (?, ?, ?)', [
		'session.turn_started',
		session_id,
		json2.encode[EventData](EventData{
			operation_id: operation_id
			status:       'running'
		}),
	]) or {
		store.db.rollback() or {}
		return error('unable to persist session operation claim event')
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit session operation claim')
	}
	return store.session_operation_unlocked(session_id, operation_id)
}

fn (mut store Store) session_operation_request_json(session_id string, operation_id string) !string {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	rows := store.db.exec_param_many('SELECT request_json FROM session_operations WHERE session_id = ? AND id = ?',
		[session_id, operation_id])!
	if rows.len != 1 {
		return error('session operation not found')
	}
	return rows[0].val(0)
}

fn (mut store Store) list_session_operations(session_id string) ![]SessionOperation {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	sessions := store.db.exec_param('SELECT id FROM sessions WHERE id = ?', session_id)!
	if sessions.len != 1 {
		return error('session not found')
	}
	rows := store.db.exec_param('SELECT id, session_id, status, provider, model, error, input_tokens, output_tokens, usage_reported, cache_read_tokens, cache_creation_tokens, cache_reported, reasoning_tokens, reasoning_reported, created_at, updated_at FROM session_operations WHERE session_id = ? ORDER BY created_at ASC, id ASC',
		session_id)!
	mut operations := []SessionOperation{cap: rows.len}
	for row in rows {
		operations << store.session_operation_from_row(row)
	}
	return operations
}

fn (mut store Store) list_queued_session_operations() ![]SessionOperation {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	rows := store.db.exec("SELECT id, session_id, status, provider, model, error, input_tokens, output_tokens, usage_reported, cache_read_tokens, cache_creation_tokens, cache_reported, reasoning_tokens, reasoning_reported, created_at, updated_at FROM session_operations WHERE status = 'queued' ORDER BY created_at ASC, id ASC")!
	mut operations := []SessionOperation{cap: rows.len}
	for row in rows {
		operations << store.session_operation_from_row(row)
	}
	return operations
}

fn (mut store Store) get_session_operation(session_id string, operation_id string) !SessionOperation {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	return store.session_operation_unlocked(session_id, operation_id)
}

fn (mut store Store) mark_session_operation_cancelling(session_id string, operation_id string) !string {
	return store.cancel_session_operation(session_id, operation_id)
}

fn (mut store Store) cancel_session_operation(session_id string, operation_id string) !string {
	return store.finish_queued_session_operation(session_id, operation_id, 'Cancelled before a worker claimed this queued turn.')
}

fn (mut store Store) reject_queued_session_operation(session_id string, operation_id string,
	public_error string) !string {
	reason := if public_error.trim_space().len > 0 {
		public_error.trim_space()
	} else {
		'Queued turn request was invalid and will not be claimed.'
	}
	if reason.len > 1024 {
		return error('queued rejection error exceeds the size limit')
	}
	return store.finish_queued_session_operation(session_id, operation_id, reason)
}

fn (mut store Store) finish_queued_session_operation(session_id string, operation_id string,
	public_error string) !string {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	rows := store.db.exec_param_many('SELECT status FROM session_operations WHERE session_id = ? AND id = ?', [
		session_id,
		operation_id,
	])!
	if rows.len == 0 {
		// Synchronous session turns share the cancellation endpoint but are not
		// persisted as async operations.
		return 'cancelling'
	}
	status := rows[0].val(0)
	if status == 'queued' {
		store.db.begin()!
		_ = store.db.exec_param_many("UPDATE session_operations SET status = 'cancelled', error = ?, updated_at = CURRENT_TIMESTAMP WHERE session_id = ? AND id = ? AND status = 'queued'",
			[public_error, session_id, operation_id]) or {
			store.db.rollback() or {}
			return error('unable to cancel queued session operation')
		}
		_ = store.db.exec_param_many('INSERT INTO events (type, session_id, data) VALUES (?, ?, ?)', [
			'session.turn_completed',
			session_id,
			json2.encode[EventData](EventData{
				operation_id: operation_id
				status:       'cancelled'
				error:        public_error
			}),
		]) or {
			store.db.rollback() or {}
			return error('unable to persist queued cancellation event')
		}
		store.db.commit() or {
			store.db.rollback() or {}
			return error('unable to commit queued cancellation')
		}
		store.prune_terminal_session_operations_unlocked(session_id)
		return 'cancelled'
	}
	if status == 'running' {
		store.db.exec_param_many("UPDATE session_operations SET status = 'cancelling', updated_at = CURRENT_TIMESTAMP WHERE session_id = ? AND id = ? AND status = 'running'",
			[session_id, operation_id])!
	}
	updated := store.db.exec_param_many('SELECT status FROM session_operations WHERE session_id = ? AND id = ?', [
		session_id,
		operation_id,
	])!
	return if updated.len == 1 { updated[0].val(0) } else { status }
}

fn (mut store Store) prune_terminal_session_operations_unlocked(session_id string) {
	count_rows := store.db.exec_param("SELECT COUNT(*) FROM session_operations WHERE session_id = ? AND status IN ('completed', 'failed', 'cancelled', 'uncertain')",
		session_id) or { return }
	if count_rows.len != 1 {
		return
	}
	limit := if store.terminal_ops_retention_limit > 0 {
		store.terminal_ops_retention_limit
	} else {
		max_retained_terminal_session_operations
	}
	excess := count_rows[0].val(0).int() - limit
	if excess <= 0 {
		return
	}
	// Prefer SQLite rowid so same-second completions still prune in insert order.
	old_rows := store.db.exec_param_many("SELECT id FROM session_operations WHERE session_id = ? AND status IN ('completed', 'failed', 'cancelled', 'uncertain') ORDER BY rowid ASC LIMIT ?",
		[session_id, excess.str()]) or { return }
	for row in old_rows {
		_ = store.db.exec_param('DELETE FROM operation_traces WHERE operation_id = ?', row.val(0)) or {
			continue
		}
		_ = store.db.exec_param_many("DELETE FROM session_operations WHERE session_id = ? AND id = ? AND status IN ('completed', 'failed', 'cancelled', 'uncertain')",
			[session_id, row.val(0)]) or { continue }
	}
}

fn (mut store Store) session_operation_unlocked(session_id string, operation_id string) !SessionOperation {
	rows := store.db.exec_param_many('SELECT id, session_id, status, provider, model, error, input_tokens, output_tokens, usage_reported, cache_read_tokens, cache_creation_tokens, cache_reported, reasoning_tokens, reasoning_reported, created_at, updated_at FROM session_operations WHERE session_id = ? AND id = ?', [
		session_id,
		operation_id,
	])!
	if rows.len != 1 {
		return error('session operation not found')
	}
	return store.session_operation_from_row(rows[0])
}

fn (store &Store) session_operation_from_row(row sqlite.Row) SessionOperation {
	usage_reported := row.val(8) == '1'
	cache_reported := row.val(11) == '1'
	reasoning_reported := row.val(13) == '1'
	return SessionOperation{
		id:                    row.val(0)
		session_id:            row.val(1)
		status:                row.val(2)
		provider:              row.val(3)
		model:                 row.val(4)
		error:                 row.val(5)
		input_tokens:          if usage_reported { row.val(6).i64() } else { 0 }
		output_tokens:         if usage_reported { row.val(7).i64() } else { 0 }
		usage_reported:        usage_reported
		cache_read_tokens:     if cache_reported { row.val(9).i64() } else { 0 }
		cache_creation_tokens: if cache_reported { row.val(10).i64() } else { 0 }
		cache_reported:        cache_reported
		reasoning_tokens:      if reasoning_reported { row.val(12).i64() } else { 0 }
		reasoning_reported:    reasoning_reported
		created_at:            row.val(14)
		updated_at:            row.val(15)
	}
}

fn (mut store Store) session_usage_summary(session_id string) !SessionUsageSummary {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	sessions := store.db.exec_param('SELECT id FROM sessions WHERE id = ?', session_id)!
	if sessions.len != 1 {
		return error('session not found')
	}
	rows := store.db.exec_param("SELECT COUNT(*), COALESCE(SUM(CASE WHEN usage_reported = 1 THEN 1 ELSE 0 END), 0), COALESCE(SUM(CASE WHEN usage_reported = 1 THEN input_tokens ELSE 0 END), 0), COALESCE(SUM(CASE WHEN usage_reported = 1 THEN output_tokens ELSE 0 END), 0), COALESCE(SUM(CASE WHEN cache_reported = 1 THEN cache_read_tokens ELSE 0 END), 0), COALESCE(SUM(CASE WHEN cache_reported = 1 THEN cache_creation_tokens ELSE 0 END), 0), COALESCE(SUM(CASE WHEN cache_reported = 1 THEN 1 ELSE 0 END), 0), COALESCE(SUM(CASE WHEN reasoning_reported = 1 THEN reasoning_tokens ELSE 0 END), 0), COALESCE(SUM(CASE WHEN reasoning_reported = 1 THEN 1 ELSE 0 END), 0) FROM session_operations WHERE session_id = ? AND status = 'completed'",
		session_id)!
	if rows.len != 1 {
		return error('unable to read session usage')
	}
	row := rows[0]
	reported_turns := row.val(1).int()
	cache_turns := row.val(6).int()
	reasoning_turns := row.val(8).int()
	return SessionUsageSummary{
		session_id:            session_id
		completed_turns:       row.val(0).int()
		reported_turns:        reported_turns
		input_tokens:          row.val(2).i64()
		output_tokens:         row.val(3).i64()
		usage_reported:        reported_turns > 0
		cache_read_tokens:     row.val(4).i64()
		cache_creation_tokens: row.val(5).i64()
		cache_reported:        cache_turns > 0
		reasoning_tokens:      row.val(7).i64()
		reasoning_reported:    reasoning_turns > 0
		cost:                  'unavailable'
	}
}

fn (mut store Store) record_session_compaction(session_id string, operation_id string,
	measurement SessionCompactionMeasurement, summary string) ! {
	if measurement.triggered == false {
		return
	}
	if !validate_operation_id(operation_id) {
		return error('invalid session operation identifier')
	}
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	store.db.begin() or {
		return error('unable to begin session compaction event')
	}
	_ = store.db.exec_param_many('INSERT INTO events (type, session_id, data) VALUES (?, ?, ?)', [
		'session.compaction',
		session_id,
		json2.encode[EventData](EventData{
			operation_id:                   operation_id
			compaction_bytes_before:        measurement.bytes_before
			compaction_bytes_after:         measurement.bytes_after
			compaction_token_bound_before:  measurement.estimated_token_bound_before
			compaction_token_bound_after:   measurement.estimated_token_bound_after
			compaction_summarized_messages: measurement.summarized_message_count
			compaction_kept_messages:       measurement.kept_message_count
			compaction_reason:              measurement.reason
			compaction_untrusted:           true
			compaction_summary_preview:     compaction_summary_preview(summary)
			compaction_summarizer_mode:     measurement.summarizer_mode
			compaction_usage_reported:      measurement.usage_reported
			compaction_input_tokens:        measurement.input_tokens
			compaction_output_tokens:       measurement.output_tokens
		}),
	]) or {
		store.db.rollback() or {}
		return error('unable to record session compaction event')
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit session compaction event')
	}
}

fn (mut store Store) record_session_repository_map(session_id string, operation_id string,
	measurement RepositoryMapMeasurement, preview string) ! {
	if measurement.injected == false {
		return
	}
	if !validate_operation_id(operation_id) {
		return error('invalid session operation identifier')
	}
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	store.db.begin() or {
		return error('unable to begin session repository map event')
	}
	_ = store.db.exec_param_many('INSERT INTO events (type, session_id, data) VALUES (?, ?, ?)', [
		'session.repository_map',
		session_id,
		json2.encode[EventData](EventData{
			operation_id:                operation_id
			repository_map_bytes:        measurement.bytes
			repository_map_token_bound:  measurement.estimated_token_bound
			repository_map_budget_bytes: measurement.budget_bytes
			repository_map_file_count:   measurement.file_count
			repository_map_symbol_count: measurement.symbol_count
			repository_map_truncated:    measurement.truncated
			repository_map_injected:     true
			repository_map_untrusted:    true
			repository_map_preview:      repository_map_summary_preview(preview)
		}),
	]) or {
		store.db.rollback() or {}
		return error('unable to record session repository map event')
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit session repository map event')
	}
}

fn (mut store Store) events_after(after int) ![]Event {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	rows := store.db.exec_param('SELECT id, type, session_id, created_at, data FROM events WHERE id > ? ORDER BY id LIMIT ${max_event_stream_page_size}',
		after.str())!
	mut events := []Event{cap: rows.len}
	for row in rows {
		data := json2.decode[EventData](row.val(4)) or {
			return error('unable to decode stored event data')
		}
		events << Event{
			id:         row.val(0).int()
			type:       row.val(1)
			session_id: row.val(2)
			created_at: row.val(3)
			data:       data
		}
	}
	return events
}

fn (mut store Store) assistant_text_for_operation(session_id string, operation_id string) !string {
	if !validate_operation_id(operation_id) {
		return error('invalid session operation identifier')
	}
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	rows := store.db.exec_param_many("SELECT data FROM events WHERE type = 'assistant.delta' AND session_id = ? AND json_extract(data, '$.operation_id') = ? ORDER BY id",
		[session_id, operation_id])!
	mut text := strings.new_builder(1024)
	mut total_bytes := 0
	for row in rows {
		event_data := json2.decode[EventData](row.val(0)) or {
			return error('unable to read assistant result events')
		}
		if total_bytes + event_data.delta.len > max_provider_stream_bytes {
			return error('assistant result exceeds the response size limit')
		}
		text.write_string(event_data.delta)
		total_bytes += event_data.delta.len
	}
	return text.str()
}

fn (mut store Store) operation_trace(session_id string, operation_id string) !string {
	if !validate_operation_id(operation_id) {
		return error('invalid session operation identifier')
	}
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	rows := store.db.exec_param_many('SELECT trajectory_json FROM operation_traces WHERE session_id = ? AND operation_id = ?',
		[session_id, operation_id])!
	if rows.len != 1 {
		return error('session operation trace not found')
	}
	return rows[0].val(0)
}

// record_operation_trace persists a trajectory independently of a completed
// exchange, so failed or cancelled turns keep their partial trace. It rejects
// a second trace for the same operation instead of replacing the first one.
fn (mut store Store) record_operation_trace(session_id string, operation_id string, trajectory_json string) ! {
	if trajectory_json.len == 0 || trajectory_json.len > max_provider_stream_bytes * 2
		|| !validate_operation_id(operation_id) {
		return error('operation trace is invalid')
	}
	_ := json2.decode[map[string]json2.Any](trajectory_json) or {
		return error('operation trace is invalid')
	}
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	_ = store.db.exec_param_many('INSERT INTO operation_traces (operation_id, session_id, trajectory_json) VALUES (?, ?, ?)',
		[operation_id, session_id, trajectory_json]) or {
		return error('unable to persist ATIF trajectory')
	}
}

fn (mut store Store) record_assistant_delta(session_id string, operation_id string, delta string) ! {
	if delta.len == 0 || delta.len > max_provider_response_bytes || delta.contains('\0')
		|| !validate_operation_id(operation_id) {
		return error('invalid streamed assistant delta')
	}
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	store.db.exec_param_many('INSERT INTO events (type, session_id, data) VALUES (?, ?, ?)', [
		'assistant.delta',
		session_id,
		json2.encode[EventData](EventData{
			operation_id: operation_id
			delta:        delta
		}),
	])!
	store.prune_session_events_unlocked(session_id)
}

fn (mut store Store) prune_session_events_unlocked(session_id string) {
	limit := if store.session_events_retention_limit > 0 {
		store.session_events_retention_limit
	} else {
		max_retained_session_events
	}
	count_rows := store.db.exec_param('SELECT COUNT(*) FROM events WHERE session_id = ?',
		session_id) or { return }
	if count_rows.len != 1 {
		return
	}
	excess := count_rows[0].val(0).int() - limit
	if excess <= 0 {
		return
	}
	_ = store.db.exec_param_many('DELETE FROM events WHERE id IN (SELECT id FROM events WHERE session_id = ? ORDER BY id ASC LIMIT ?)',
		[session_id, excess.str()]) or { return }
}

fn (mut store Store) messages_for_session(session_id string, limit int) ![]ChatTurn {
	return store.messages_page_for_session(session_id, limit, 0)!
}

fn (mut store Store) messages_page_for_session(session_id string, limit int, before_id int) ![]ChatTurn {
	if limit < 1 || limit > max_session_history_page_size || before_id < 0 {
		return error('chat history page bounds are invalid')
	}
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	query := 'SELECT id, session_id, role, content, created_at FROM (SELECT id, session_id, role, content, created_at FROM messages WHERE session_id = ?'
	mut params := [session_id]
	mut cursor_filter := ''
	if before_id > 0 {
		cursor_filter = ' AND id < ?'
		params << before_id.str()
	}
	params << limit.str()
	rows := store.db.exec_param_many('${query}${cursor_filter} ORDER BY id DESC LIMIT ?) ORDER BY id',
		params)!
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

fn (mut store Store) append_exchange(session_id string, operation_id string, user_content string,
	assistant_content string, provider string, model string, trajectory_json string,
	usage ProviderUsage) ![]ChatTurn {
	if trajectory_json.len > max_provider_stream_bytes * 2 {
		return error('operation trace exceeds the persistence size limit')
	}
	if trajectory_json.len > 0 {
		if !validate_operation_id(operation_id) {
			return error('operation trace is invalid')
		}
		_ := json2.decode[map[string]json2.Any](trajectory_json) or {
			return error('operation trace is invalid')
		}
	}
	if usage.reported
		&& (usage.input_tokens < 0 || usage.output_tokens < 0 || usage.cache_read_tokens < 0
			|| usage.cache_creation_tokens < 0 || usage.reasoning_tokens < 0) {
		return error('provider usage token counts must be non-negative')
	}
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
	if operation_id.len > 0 {
		input_tokens := if usage.reported { usage.input_tokens } else { i64(0) }
		output_tokens := if usage.reported { usage.output_tokens } else { i64(0) }
		usage_flag := if usage.reported { '1' } else { '0' }
		cache_read_tokens := if usage.cache_reported { usage.cache_read_tokens } else { i64(0) }
		cache_creation_tokens := if usage.cache_reported {
			usage.cache_creation_tokens
		} else {
			i64(0)
		}
		cache_flag := if usage.cache_reported { '1' } else { '0' }
		reasoning_tokens := if usage.reasoning_reported { usage.reasoning_tokens } else { i64(0) }
		reasoning_flag := if usage.reasoning_reported { '1' } else { '0' }
		_ = store.db.exec_param_many("UPDATE session_operations SET status = 'completed', provider = ?, model = ?, error = '', input_tokens = ?, output_tokens = ?, usage_reported = ?, cache_read_tokens = ?, cache_creation_tokens = ?, cache_reported = ?, reasoning_tokens = ?, reasoning_reported = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND session_id = ? AND status IN ('running', 'cancelling')",
			[provider, model, input_tokens.str(), output_tokens.str(), usage_flag,
				cache_read_tokens.str(), cache_creation_tokens.str(), cache_flag,
				reasoning_tokens.str(), reasoning_flag, operation_id, session_id]) or {
			store.db.rollback() or {}
			return error('unable to persist session operation result')
		}
		completion := if usage.reported {
			EventData{
				operation_id:          operation_id
				status:                'completed'
				provider:              provider
				model:                 model
				input_tokens:          input_tokens
				output_tokens:         output_tokens
				usage_reported:        true
				cache_read_tokens:     cache_read_tokens
				cache_creation_tokens: cache_creation_tokens
				cache_reported:        usage.cache_reported
				reasoning_tokens:      reasoning_tokens
				reasoning_reported:    usage.reasoning_reported
			}
		} else {
			EventData{
				operation_id: operation_id
				status:       'completed'
				provider:     provider
				model:        model
			}
		}
		_ = store.db.exec_param_many('INSERT INTO events (type, session_id, data) VALUES (?, ?, ?)', [
			'session.turn_completed',
			session_id,
			json2.encode[EventData](completion),
		]) or {
			store.db.rollback() or {}
			return error('unable to persist session turn completion')
		}
		if trajectory_json.len > 0 {
			_ = store.db.exec_param_many('INSERT INTO operation_traces (operation_id, session_id, trajectory_json) VALUES (?, ?, ?)',
				[operation_id, session_id, trajectory_json]) or {
				store.db.rollback() or {}
				return error('unable to persist ATIF trajectory')
			}
		}
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit chat exchange')
	}
	store.prune_session_events_unlocked(session_id)
	if operation_id.len > 0 {
		store.prune_terminal_session_operations_unlocked(session_id)
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

fn (mut store Store) record_session_turn_completion(session_id string, operation_id string,
	status string, public_error string, user_content string, assistant_content string) ! {
	if !validate_operation_id(operation_id) || operation_id.len == 0
		|| status !in ['failed', 'cancelled'] || public_error.len > 1024
		|| user_content.len > max_chat_input_bytes || assistant_content.len > max_provider_stream_bytes {
		return error('invalid session turn completion')
	}
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
	// A failed or cancelled turn still belongs in the transcript. The user
	// prompt is stored here because the successful exchange path is the only
	// other writer of chat messages.
	for turn in [ChatTurn{
		role:    'user'
		content: user_content
	}, ChatTurn{
		role:    'assistant'
		content: assistant_content
	}] {
		if turn.content.len == 0 {
			continue
		}
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
	_ = store.db.exec_param_many('INSERT INTO events (type, session_id, data) VALUES (?, ?, ?)', [
		'session.turn_completed',
		session_id,
		json2.encode[EventData](EventData{
			operation_id: operation_id
			status:       status
			error:        public_error
		}),
	]) or {
		store.db.rollback() or {}
		return error('unable to persist session turn completion')
	}
	_ = store.db.exec_param_many("UPDATE session_operations SET status = ?, error = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND session_id = ? AND status IN ('queued', 'running', 'cancelling')", [
		status,
		public_error,
		operation_id,
		session_id,
	]) or {
		store.db.rollback() or {}
		return error('unable to persist session operation failure')
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit session turn completion')
	}
	store.prune_terminal_session_operations_unlocked(session_id)
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

fn (mut store Store) create_plugin_mcp_tool_call(session_id string, operation_id string,
	plugin_name string, server_name string, tool_name string, arguments string) !PluginMCPToolCallApproval {
	if arguments.len > max_plugin_mcp_tool_call_argument_bytes {
		return error('MCP tool arguments exceed the size limit')
	}
	_ := json2.decode[map[string]json2.Any](arguments) or {
		return error('MCP tool arguments must be a JSON object')
	}
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
	pending := store.db.exec_param_many("SELECT COUNT(*) FROM plugin_mcp_tool_calls WHERE session_id = ? AND status IN ('pending', 'approved', 'running')",
		[session_id]) or {
		store.db.rollback() or {}
		return error('unable to inspect pending MCP tool calls')
	}
	if pending.len != 1 || pending[0].val(0).int() >= max_pending_plugin_mcp_tool_calls {
		store.db.rollback() or {}
		return error('pending MCP tool call limit reached')
	}
	id := uuid.new_v4().str()
	_ = store.db.exec_param_many('INSERT INTO plugin_mcp_tool_calls (id, session_id, operation_id, plugin_name, server_name, tool_name, arguments, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', [
		id,
		session_id,
		operation_id,
		plugin_name,
		server_name,
		tool_name,
		arguments,
		'pending',
	]) or {
		store.db.rollback() or {}
		return error('unable to persist MCP tool call approval')
	}
	_ = store.db.exec_param_many('INSERT INTO events (type, session_id) VALUES (?, ?)', [
		'plugin.mcp_tool_call_pending',
		session_id,
	]) or {
		store.db.rollback() or {}
		return error('unable to publish MCP tool call approval')
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit MCP tool call approval')
	}
	return store.get_plugin_mcp_tool_call_unlocked(session_id, id)!
}

fn (mut store Store) plugin_mcp_tool_calls(session_id string) ![]PluginMCPToolCallSummary {
	store.mu.lock()
	defer { store.mu.unlock() }
	rows := store.db.exec_param_many('SELECT id, operation_id, plugin_name, server_name, tool_name, length(CAST(arguments AS BLOB)), status, COALESCE(reviewed_at, ""), created_at, updated_at FROM plugin_mcp_tool_calls WHERE session_id = ? ORDER BY created_at DESC, id DESC LIMIT ${max_plugin_mcp_tool_call_history}',
		[session_id])!
	mut calls := []PluginMCPToolCallSummary{cap: rows.len}
	for row in rows {
		calls << plugin_mcp_tool_call_summary_from_row(row)
	}
	return calls
}

fn plugin_mcp_tool_call_summary_from_row(row sqlite.Row) PluginMCPToolCallSummary {
	return PluginMCPToolCallSummary{
		id:              row.val(0)
		operation_id:    row.val(1)
		plugin_name:     row.val(2)
		server_name:     row.val(3)
		tool_name:       row.val(4)
		arguments_bytes: row.val(5).int()
		status:          row.val(6)
		reviewed_at:     row.val(7)
		created_at:      row.val(8)
		updated_at:      row.val(9)
	}
}

fn (mut store Store) review_plugin_mcp_tool_call(session_id string, id string) !PluginMCPToolCallApproval {
	store.mu.lock()
	defer { store.mu.unlock() }
	store.db.begin()!
	call := store.get_plugin_mcp_tool_call_unlocked(session_id, id) or {
		store.db.rollback() or {}
		return err
	}
	if call.status == 'pending' && call.reviewed_at.len == 0 {
		_ = store.db.exec_param_many("UPDATE plugin_mcp_tool_calls SET reviewed_at = CURRENT_TIMESTAMP WHERE id = ? AND session_id = ? AND status = 'pending' AND reviewed_at IS NULL",
			[id, session_id]) or {
			store.db.rollback() or {}
			return error('unable to record MCP tool call review')
		}
		if store.db.get_affected_rows_count() != 1 {
			store.db.rollback() or {}
			return error('MCP tool call changed while being reviewed')
		}
		_ = store.db.exec_param_many('INSERT INTO events (type, session_id) VALUES (?, ?)',
			['plugin.mcp_tool_call_reviewed', session_id]) or {
			store.db.rollback() or {}
			return error('unable to record MCP tool call review event')
		}
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit MCP tool call review')
	}
	return store.get_plugin_mcp_tool_call_unlocked(session_id, id)!
}

fn (mut store Store) approve_plugin_mcp_tool_call(session_id string, id string) ! {
	store.transition_plugin_mcp_tool_call(session_id, id, 'approved', "status = 'pending' AND reviewed_at IS NOT NULL",
		'plugin.mcp_tool_call_approved')!
}

fn (mut store Store) reject_plugin_mcp_tool_call(session_id string, id string) ! {
	store.transition_plugin_mcp_tool_call(session_id, id, 'rejected', "status = 'pending'",
		'plugin.mcp_tool_call_rejected')!
}

fn (mut store Store) begin_plugin_mcp_tool_call(session_id string, id string) ! {
	store.transition_plugin_mcp_tool_call(session_id, id, 'running', "status = 'approved'",
		'plugin.mcp_tool_call_running')!
}

fn (mut store Store) finish_plugin_mcp_tool_call(session_id string, id string, status string) ! {
	if status !in ['completed', 'failed', 'cancelled'] {
		return error('invalid MCP tool call result status')
	}
	store.transition_plugin_mcp_tool_call(session_id, id, status, "status = 'running'",
		'plugin.mcp_tool_call_${status}')!
}

fn (mut store Store) cancel_plugin_mcp_tool_call(session_id string, id string) ! {
	store.transition_plugin_mcp_tool_call(session_id, id, 'cancelled', "status IN ('pending', 'approved')",
		'plugin.mcp_tool_call_cancelled')!
}

fn (mut store Store) transition_plugin_mcp_tool_call(session_id string, id string,
	status string, expected string, event_type string) ! {
	store.mu.lock()
	defer { store.mu.unlock() }
	store.db.begin()!
	query := 'UPDATE plugin_mcp_tool_calls SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND session_id = ? AND ${expected}'
	_ = store.db.exec_param_many(query, [status, id, session_id]) or {
		store.db.rollback() or {}
		return error('unable to update MCP tool call status')
	}
	if store.db.get_affected_rows_count() != 1 {
		store.db.rollback() or {}
		return error('MCP tool call is no longer in the expected state')
	}
	_ = store.db.exec_param_many('INSERT INTO events (type, session_id) VALUES (?, ?)',
		[event_type, session_id]) or {
		store.db.rollback() or {}
		return error('unable to record MCP tool call status')
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit MCP tool call status')
	}
}

fn (mut store Store) get_plugin_mcp_tool_call(session_id string, id string) !PluginMCPToolCallApproval {
	store.mu.lock()
	defer { store.mu.unlock() }
	return store.get_plugin_mcp_tool_call_unlocked(session_id, id)
}

fn (mut store Store) get_plugin_mcp_tool_call_unlocked(session_id string,
	id string) !PluginMCPToolCallApproval {
	rows := store.db.exec_param_many('SELECT id, operation_id, plugin_name, server_name, tool_name, arguments, status, COALESCE(reviewed_at, ""), created_at, updated_at FROM plugin_mcp_tool_calls WHERE session_id = ? AND id = ?',
		[session_id, id])!
	if rows.len != 1 {
		return error('MCP tool call not found')
	}
	return plugin_mcp_tool_call_from_row(rows[0])
}

fn plugin_mcp_tool_call_from_row(row sqlite.Row) PluginMCPToolCallApproval {
	return PluginMCPToolCallApproval{
		id:             row.val(0)
		operation_id:   row.val(1)
		plugin_name:    row.val(2)
		server_name:    row.val(3)
		tool_name:      row.val(4)
		arguments_json: row.val(5)
		status:         row.val(6)
		reviewed_at:    row.val(7)
		created_at:     row.val(8)
		updated_at:     row.val(9)
	}
}
