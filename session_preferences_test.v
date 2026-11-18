module main

import db.sqlite
import json2
import net
import net.http
import os
import time
import uuid
import veb

fn prefs_test_root(label string) string {
	root := os.join_path(os.temp_dir(), 'veasel-prefs-${label}-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	return root
}

fn prefs_fixture_path() string {
	return os.join_path(os.dir(@FILE), 'testing', 'fixtures', 'store_v30.sqlite')
}

fn prefs_app(root string) (&Store, &App) {
	store := open_store(os.join_path(root, 'data', 'veasel.sqlite3')) or { panic(err) }
	plugin_dir := os.join_path(root, 'plugins')
	os.mkdir_all(plugin_dir) or { panic(err) }
	return store, new_app(store, plugin_dir)
}

// --- migration -------------------------------------------------------------

fn test_migration_from_real_v30_database_preserves_rows_and_is_idempotent() {
	root := prefs_test_root('migrate')
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'veasel.sqlite3')
	os.cp(prefs_fixture_path(), path) or { panic(err) }

	// Prove the fixture really is a v30 database before upgrading it.
	before := open_store_at_version_probe(path)
	assert before == 30

	mut store := open_store(path) or { panic(err) }
	sessions := store.list_sessions() or { panic(err) }
	assert sessions.len == 2
	completed := sessions.filter(it.title == 'Legacy completed')[0]
	failed := sessions.filter(it.title == 'Legacy failed')[0]
	assert completed.directory == '/work/legacy-a'
	// Defaults for rows written before the migration.
	assert completed.preferred_provider == ''
	assert completed.preferred_model == ''
	assert completed.permission_mode == 'ask'
	assert completed.prefs_version == 0
	// last_* is read from the executed operation, never from a preference.
	assert completed.last_provider == 'claude'
	assert completed.last_model == 'sonnet'
	assert failed.last_provider == ''
	// Existing history is untouched.
	messages := store.messages_for_session(completed.id, 10) or { panic(err) }
	assert messages.len == 2
	assert messages[0].content == 'hello'
	operations := store.list_session_operations(completed.id) or { panic(err) }
	assert operations.len == 1
	assert operations[0].status == 'completed'
	assert operations[0].resolved_provider == ''
	store.close() or { panic(err) }

	assert open_store_at_version_probe(path) == latest_schema_version
	// Reopening must not re-run or duplicate the migration.
	mut again := open_store(path) or { panic(err) }
	assert (again.list_sessions() or { panic(err) }).len == 2
	again.close() or { panic(err) }
	assert open_store_at_version_probe(path) == latest_schema_version
}

fn open_store_at_version_probe(path string) int {
	// Read the ledger directly: open_store would migrate the file first.
	mut db := sqlite.connect(path) or { panic(err) }
	defer { db.close() or {} }
	return db.q_int('SELECT COALESCE(MAX(version), 0) FROM schema_migrations') or { panic(err) }
}

fn test_migration_31_is_rerunnable_when_its_ledger_row_is_missing() {
	root := prefs_test_root('rerun')
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'veasel.sqlite3')
	mut store := open_store(path) or { panic(err) }
	store.db.exec('DELETE FROM schema_migrations WHERE version >= 31') or { panic(err) }
	store.close() or { panic(err) }
	// Columns already exist; the migration must adopt them, not fail.
	mut again := open_store(path) or { panic(err) }
	defer { again.close() or {} }
	assert again.db.q_int('SELECT MAX(version) FROM schema_migrations') or { panic(err) } == latest_schema_version
}

// --- store -----------------------------------------------------------------

fn test_session_preferences_persist_across_store_restart() {
	root := prefs_test_root('restart')
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'veasel.sqlite3')
	mut store := open_store(path) or { panic(err) }
	created := store.create_session(SessionInput{
		title:              'prefs'
		directory:          root
		preferred_provider: 'codex'
		permission_mode:    'accept-edits'
	}) or { panic(err) }
	assert created.preferred_provider == 'codex'
	assert created.permission_mode == 'accept-edits'
	assert created.prefs_version == 0
	updated := store.update_session_preferences(created.id, 0, SessionPreferencesPatch{
		set_target:         true
		preferred_provider: 'claude-code'
	}) or { panic(err) }
	assert updated.prefs_version == 1
	assert updated.permission_mode == 'accept-edits'
	store.close() or { panic(err) }

	mut reopened := open_store(path) or { panic(err) }
	defer { reopened.close() or {} }
	loaded := reopened.get_session(created.id) or { panic(err) }
	assert loaded.preferred_provider == 'claude-code'
	assert loaded.permission_mode == 'accept-edits'
	assert loaded.prefs_version == 1
}

fn test_update_session_preferences_rejects_stale_version_and_active_turns() {
	root := prefs_test_root('conflict')
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{ title: 'c', directory: root }) or { panic(err) }
	_ = store.update_session_preferences(session.id, 0, SessionPreferencesPatch{
		set_permission:  true
		permission_mode: 'plan'
	}) or { panic(err) }
	store.update_session_preferences(session.id, 0, SessionPreferencesPatch{
		set_permission:  true
		permission_mode: 'ask'
	}) or {
		assert err.msg() == 'prefs_version_conflict'
		operation_id := uuid.new_v4().str()
		store.create_session_operation(session.id, operation_id) or { panic(err) }
		store.update_session_preferences(session.id, 1, SessionPreferencesPatch{
			set_permission:  true
			permission_mode: 'ask'
		}) or {
			assert err.msg() == 'session_busy'
			assert (store.get_session(session.id) or { panic(err) }).permission_mode == 'plan'
			return
		}
		assert false, 'a running turn must block preference changes'
		return
	}
	assert false, 'a stale prefs_version must be rejected'
}

fn test_bypass_requires_confirmation_and_is_audited() {
	root := prefs_test_root('bypass')
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	store.create_session(SessionInput{
		title:           'no confirm'
		directory:       root
		permission_mode: 'bypass'
	}) or {
		assert err.msg() == 'bypass_confirmation_required'
		session := store.create_session(SessionInput{ title: 's', directory: root }) or { panic(err) }
		assert session.permission_mode == 'ask'
		store.update_session_preferences(session.id, 0, SessionPreferencesPatch{
			set_permission:  true
			permission_mode: 'bypass'
		}) or {
			assert err.msg() == 'bypass_confirmation_required'
			assert (store.get_session(session.id) or { panic(err) }).permission_mode == 'ask'
			confirmed := store.update_session_preferences(session.id, 0, SessionPreferencesPatch{
				set_permission:  true
				permission_mode: 'bypass'
				confirm_bypass:  true
			}) or { panic(err) }
			assert confirmed.permission_mode == 'bypass'
			audit := store.db.exec_param("SELECT COUNT(*) FROM events WHERE session_id = ? AND type = 'session.permission_bypass_confirmed'",
				session.id) or { panic(err) }
			assert audit[0].val(0).int() == 1
			// Leaving bypass is not an elevation and needs no confirmation.
			back := store.update_session_preferences(session.id, 1, SessionPreferencesPatch{
				set_permission:  true
				permission_mode: 'ask'
			}) or { panic(err) }
			assert back.permission_mode == 'ask'
			return
		}
		assert false, 'bypass without confirmation must be rejected'
		return
	}
	assert false, 'creating a bypass session without confirmation must be rejected'
}

fn test_fork_keeps_target_but_never_inherits_permission_mode() {
	root := prefs_test_root('fork')
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	source := store.create_session(SessionInput{
		title:              'fork me'
		directory:          root
		preferred_provider: 'codex'
		permission_mode:    'bypass'
		confirm_bypass:     true
	}) or { panic(err) }
	fork := store.fork_session(source.id) or { panic(err) }
	assert fork.preferred_provider == 'codex'
	assert fork.permission_mode == 'ask'
}

// --- resolution ------------------------------------------------------------

fn test_turn_resolution_prefers_turn_over_session_over_default() {
	root := prefs_test_root('resolve')
	defer { os.rmdir_all(root) or {} }
	mut store, mut app := prefs_app(root)
	defer {
		app.close()
		store.close() or {}
	}
	session := Session{
		id:                 'resolve-session'
		preferred_provider: 'codex'
		permission_mode:    'plan'
	}
	from_session := app.resolve_turn_preferences(session, ChatMessageInput{ content: 'x' }) or {
		panic(err)
	}
	assert from_session.target_source == 'session'
	assert from_session.input.provider == 'codex'
	assert from_session.input.permission_mode == 'plan'
	assert from_session.permission_source == 'session'

	from_turn := app.resolve_turn_preferences(session, ChatMessageInput{
		content:         'x'
		provider:        'claude-code'
		permission_mode: 'accept-edits'
	}) or { panic(err) }
	assert from_turn.target_source == 'turn'
	assert from_turn.input.provider == 'claude-code'
	assert from_turn.input.permission_mode == 'accept-edits'
	assert from_turn.permission_source == 'turn'

	unset := Session{
		id: 'resolve-default'
	}
	from_default := app.resolve_turn_preferences(unset, ChatMessageInput{ content: 'x' }) or {
		panic(err)
	}
	assert from_default.target_source == 'default'
	// The global default stays unpinned, but the permission is always explicit.
	assert from_default.input.provider == ''
	assert from_default.input.permission_mode == 'ask'
}

fn test_turn_resolution_never_falls_back_when_the_stored_provider_is_gone() {
	root := prefs_test_root('gone')
	defer { os.rmdir_all(root) or {} }
	mut store, mut app := prefs_app(root)
	defer {
		app.close()
		store.close() or {}
	}
	gone := Session{
		id:                 'gone'
		preferred_provider: 'removed-provider'
		preferred_model:    'm'
		permission_mode:    'ask'
	}
	app.resolve_turn_preferences(gone, ChatMessageInput{ content: 'x' }) or {
		assert err.msg() == 'session_provider_unavailable'
		return
	}
	assert false, 'an unavailable stored provider must not resolve to another provider'
}

fn test_turn_resolution_fails_closed_for_unsupported_permission_mode() {
	root := prefs_test_root('unsupported')
	defer { os.rmdir_all(root) or {} }
	mut store, mut app := prefs_app(root)
	defer {
		app.close()
		store.close() or {}
	}
	session := Session{
		id:                 'unsupported'
		preferred_provider: 'opencode'
		permission_mode:    'accept-edits'
	}
	app.resolve_turn_preferences(session, ChatMessageInput{ content: 'x' }) or {
		assert err.msg().starts_with('session_permission_unsupported:')
		return
	}
	assert false, 'a mode the provider cannot honor must be rejected, not downgraded'
}

fn test_stamp_session_operation_records_resolution_and_audits_bypass() {
	root := prefs_test_root('stamp')
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{ title: 's', directory: root }) or { panic(err) }
	operation_id := uuid.new_v4().str()
	store.enqueue_session_operation(session.id, operation_id, '{"content":"hi"}') or { panic(err) }
	store.stamp_session_operation(session.id, operation_id, 'codex', '', 'bypass', 'turn') or {
		panic(err)
	}
	operation := store.get_session_operation(session.id, operation_id) or { panic(err) }
	assert operation.resolved_provider == 'codex'
	assert operation.permission_mode == 'bypass'
	assert operation.target_source == 'turn'
	// executed provider stays empty until the turn runs
	assert operation.provider == ''
	audit := store.db.exec_param("SELECT COUNT(*) FROM events WHERE session_id = ? AND type = 'session.permission_bypass_confirmed'",
		session.id) or { panic(err) }
	assert audit[0].val(0).int() == 1
}

// --- HTTP ------------------------------------------------------------------

struct PrefsHTTPServer {
	app          &App
	server_ready chan &veb.Server
}

pub fn (mut app PrefsHTTPServer) init_server(server &veb.Server) {
	app.server_ready <- server
}

@['/v1/sessions'; post]
pub fn (mut app PrefsHTTPServer) create(mut ctx Context) veb.Result {
	return app.app.create_session(mut ctx)
}

@['/v1/sessions/:id'; get]
pub fn (mut app PrefsHTTPServer) read(mut ctx Context, id string) veb.Result {
	return app.app.get_session(mut ctx, id)
}

@['/v1/sessions/:id'; patch]
pub fn (mut app PrefsHTTPServer) patch(mut ctx Context, id string) veb.Result {
	return app.app.rename_session(mut ctx, id)
}

fn run_prefs_http_server(mut app PrefsHTTPServer, port int) {
	veb.run_at[PrefsHTTPServer, Context](mut app, host: '127.0.0.1', family: .ip, port: port) or {
		panic(err)
	}
}

fn start_prefs_http(app &App) (&veb.Server, thread, int) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	port := listener.addr() or { panic(err) }.port() or { panic(err) }
	listener.close() or { panic(err) }
	mut server_app := &PrefsHTTPServer{
		app:          unsafe { app }
		server_ready: chan &veb.Server{cap: 1}
	}
	server_thread := spawn run_prefs_http_server(mut server_app, port)
	server := <-server_app.server_ready
	server.wait_till_running() or { panic(err) }
	return server, server_thread, port
}

fn prefs_request(method http.Method, url string, body string) http.Response {
	return http.fetch(
		url:           url
		method:        method
		data:          body
		header:        http.new_header_from_map({
			http.CommonHeader.content_type: 'application/json'
		})
		read_timeout:  10 * time.second
		write_timeout: 10 * time.second
	) or { panic(err) }
}

fn test_http_session_preferences_validation_conflict_and_restart() {
	root := prefs_test_root('http')
	defer { os.rmdir_all(root) or {} }
	workspace := os.join_path(root, 'workspace')
	os.mkdir_all(workspace) or { panic(err) }
	data_path := os.join_path(root, 'data', 'veasel.sqlite3')

	mut store := open_store(data_path) or { panic(err) }
	plugin_dir := os.join_path(root, 'plugins')
	os.mkdir_all(plugin_dir) or { panic(err) }
	mut app := new_app(store, plugin_dir)
	server, server_thread, port := start_prefs_http(app)
	base := 'http://127.0.0.1:${port}/v1/sessions'

	created := prefs_request(.post, base, json2.encode({
		'title':              json2.Any('http prefs')
		'directory':          json2.Any(workspace)
		'preferred_provider': json2.Any('codex')
		'permission_mode':    json2.Any('plan')
	}))
	assert created.status_code == 201
	session := json2.decode[Session](created.body) or { panic(err) }
	assert session.preferred_provider == 'codex'
	assert session.permission_mode == 'plan'
	assert session.prefs_version == 0
	url := '${base}/${session.id}'

	// Validation mirrors the per-turn target rules.
	model_only := prefs_request(.patch, url, '{"preferred_model":"gpt","expected_prefs_version":0}')
	assert model_only.status_code == 400, model_only.body
	assert model_only.body.contains('provider and model must be supplied together'), model_only.body
	unknown_mode := prefs_request(.patch, url, '{"permission_mode":"yolo","expected_prefs_version":0}')
	assert unknown_mode.status_code == 400
	missing_version := prefs_request(.patch, url, '{"permission_mode":"ask"}')
	assert missing_version.status_code == 400
	assert missing_version.body.contains('expected_prefs_version')
	unsupported := prefs_request(.patch, url, '{"preferred_provider":"opencode","expected_prefs_version":0}')
	assert unsupported.status_code == 400
	assert unsupported.body.contains('does not support permission mode')
	no_confirm := prefs_request(.patch, url, '{"permission_mode":"bypass","expected_prefs_version":0}')
	assert no_confirm.status_code == 400
	assert no_confirm.body.contains('confirm_bypass')
	// None of the rejected requests changed anything.
	unchanged := json2.decode[Session](prefs_request(.get, url, '').body) or { panic(err) }
	assert unchanged.prefs_version == 0
	assert unchanged.permission_mode == 'plan'

	ok := prefs_request(.patch, url, '{"preferred_provider":"claude-code","permission_mode":"accept-edits","expected_prefs_version":0}')
	assert ok.status_code == 200
	changed := json2.decode[Session](ok.body) or { panic(err) }
	assert changed.preferred_provider == 'claude-code'
	assert changed.permission_mode == 'accept-edits'
	assert changed.prefs_version == 1

	stale := prefs_request(.patch, url, '{"permission_mode":"ask","expected_prefs_version":0}')
	assert stale.status_code == 409
	conflict := json2.decode[SessionPreferencesConflict](stale.body) or { panic(err) }
	assert conflict.code == 'prefs_version_conflict'
	assert conflict.session.prefs_version == 1
	assert conflict.session.preferred_provider == 'claude-code'

	// Title-only rename keeps working without a version.
	renamed := prefs_request(.patch, url, '{"title":"renamed"}')
	assert renamed.status_code == 200
	assert (json2.decode[Session](renamed.body) or { panic(err) }).title == 'renamed'

	// A turn in flight blocks changes (synchronous turns only live in memory).
	operation_id := uuid.new_v4().str()
	_, _, cancel := app.begin_queued_turn_operation(session.id, operation_id) or { panic(err) }
	busy := prefs_request(.patch, url, '{"permission_mode":"ask","expected_prefs_version":1}')
	assert busy.status_code == 409
	assert (json2.decode[SessionPreferencesConflict](busy.body) or { panic(err) }).code == 'session_busy'
	app.finish_turn_operation(operation_id)
	cancel()

	server.shutdown(timeout: 5 * time.second) or {}
	server_thread.wait()
	app.close()
	store.close() or {}

	// Restart: a new process opening the same database sees the same choices.
	mut store2 := open_store(data_path) or { panic(err) }
	mut app2 := new_app(store2, plugin_dir)
	server2, server_thread2, port2 := start_prefs_http(app2)
	defer {
		server2.shutdown(timeout: 5 * time.second) or {}
		server_thread2.wait()
		app2.close()
		store2.close() or {}
	}
	after := json2.decode[Session](prefs_request(.get, 'http://127.0.0.1:${port2}/v1/sessions/${session.id}', '').body) or {
		panic(err)
	}
	assert after.preferred_provider == 'claude-code'
	assert after.permission_mode == 'accept-edits'
	assert after.prefs_version == 1
	assert after.title == 'renamed'
}
