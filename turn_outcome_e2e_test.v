module main

import json2
import net
import net.http
import os
import time
import uuid
import veb

// End-to-end durable turn outcomes (epic #689, item B) against the scripted
// fake CLI in testing/fake-claude-outcomes.mjs. The reproduction case is the
// audited one: an approved edit is applied, tests pass, a later shell
// approval expires, and the whole turn used to be recorded as a generic
// failure that hid the applied edit.

struct OutcomeHTTPServer {
	app          &App
	server_ready chan &veb.Server
}

pub fn (mut app OutcomeHTTPServer) init_server(server &veb.Server) {
	app.server_ready <- server
}

@['/v1/sessions/:id/messages'; post]
pub fn (mut app OutcomeHTTPServer) send(mut ctx Context, id string) veb.Result {
	return app.app.send_session_message(mut ctx, id)
}

fn run_outcome_http_server(mut app OutcomeHTTPServer, port int) {
	outcome_test_install_token()
	veb.run_at[OutcomeHTTPServer, Context](mut app, host: '127.0.0.1', family: .ip, port: port) or {
		panic(err)
	}
}

struct OutcomeTurn {
	status_code int
	events      []string
	applied     string
}

fn outcome_node_available() bool {
	return os.execute('node --version').exit_code == 0
}

// run_outcome_turn executes one scripted turn through the real HTTP handler
// with interactive approvals on. The test acts as the human: it approves
// `approve_tools` and never answers the rest, so they expire.
fn run_outcome_turn(scenario string, approve_tools []string) OutcomeTurn {
	fixture := os.join_path(os.dir(@FILE), 'testing', 'fake-claude-outcomes.mjs')
	root := os.join_path(os.temp_dir(), 'veasel-outcome-${uuid.new_v4().str()}')
	workspace := os.join_path(root, 'workspace')
	shim_dir := os.join_path(root, 'bin')
	os.mkdir_all(workspace) or { panic(err) }
	os.mkdir_all(shim_dir) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	math_path := os.join_path(workspace, 'math.js')
	os.write_file(math_path, 'export const add = (a, b) => a - b\n') or { panic(err) }
	shim := os.join_path(shim_dir, 'claude')
	os.write_file(shim, '#!/bin/sh\nexec node "${fixture}" "\$@"\n') or { panic(err) }
	os.chmod(shim, 0o755) or { panic(err) }
	old_path := os.getenv('PATH')
	os.setenv('PATH', shim_dir + ':' + old_path, true)
	os.setenv('VEASEL_CLI_INTERACTIVE_APPROVALS', '1', true)
	// A short approval bound keeps the test fast; builds that predate the
	// bound ignore it and wait for the CLI turn timeout instead.
	os.setenv('VEASEL_CLI_APPROVAL_TIMEOUT_SECONDS', '1', true)
	defer {
		os.setenv('PATH', old_path, true)
		os.unsetenv('VEASEL_CLI_INTERACTIVE_APPROVALS')
		os.unsetenv('VEASEL_CLI_APPROVAL_TIMEOUT_SECONDS')
	}

	mut store := open_store(os.join_path(root, 'data', 'veasel.sqlite3')) or { panic(err) }
	plugin_dir := os.join_path(root, 'plugins')
	os.mkdir_all(plugin_dir) or { panic(err) }
	mut app := new_app(store, plugin_dir)
	// A global default must exist for the turn to be admitted; the explicit
	// CLI provider on the request is what actually runs. Nothing contacts it.
	mut settings := app.model_settings
	settings.update(ModelSettingsInput{
		provider: 'openai-compatible'
		model:    'unused-default'
		base_url: 'http://127.0.0.1:9/v1'
		api_key:  'fixture-only-key'
	}) or { panic(err) }
	session := store.create_session(SessionInput{
		title:     'outcomes'
		directory: workspace
	}) or { panic(err) }
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	port := listener.addr() or { panic(err) }.port() or { panic(err) }
	listener.close() or { panic(err) }
	mut server_app := &OutcomeHTTPServer{
		app:          unsafe { app }
		server_ready: chan &veb.Server{cap: 1}
	}
	server_thread := spawn run_outcome_http_server(mut server_app, port)
	server := <-server_app.server_ready
	server.wait_till_running() or { panic(err) }

	done := chan int{cap: 1}
	spawn fn (url string, body string, done chan int) {
		response := http.fetch(
			url:           url
			method:        .post
			data:          body
			header:        http.new_header_from_map({
				http.CommonHeader.content_type:  'application/json'
				http.CommonHeader.authorization: 'Bearer aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
			})
			read_timeout:  300 * time.second
			write_timeout: 30 * time.second
		) or {
			done <- -1
			return
		}
		done <- response.status_code
	}('http://127.0.0.1:${port}/v1/sessions/${session.id}/messages', json2.encode({
		'content':         json2.Any(scenario)
		'provider':        json2.Any('claude-code')
		'permission_mode': json2.Any('ask')
	}), done)

	// Play the human: approve the requested tools, leave the rest pending.
	mut status_code := -2
	deadline := time.now().add(280 * time.second)
	for time.now() < deadline {
		select {
			code := <-done {
				status_code = code
			}
			100 * time.millisecond {
				pending := store.list_pending_cli_tool_approvals(session.id) or { []CliToolApproval{} }
				for approval in pending {
					if approval.tool_name in approve_tools && approval.input_json.contains('math.js') {
						store.decide_cli_tool_approval(session.id, approval.id, true) or {}
					}
				}
			}
		}
		if status_code != -2 {
			break
		}
	}
	rows := store.db.exec_param("SELECT data FROM events WHERE session_id = ? AND type = 'session.turn_completed' ORDER BY id", session.id) or {
		panic(err)
	}
	mut events := []string{}
	for row in rows {
		events << row.val(0)
	}
	applied := os.read_file(math_path) or { '' }
	server.shutdown(timeout: 5 * time.second) or {}
	server_thread.wait()
	app.close()
	store.close() or {}
	return OutcomeTurn{
		status_code: status_code
		events:      events
		applied:     applied
	}
}

fn outcome_of(turn OutcomeTurn) (string, string) {
	assert turn.events.len == 1, 'expected one turn_completed event, got ${turn.events}'
	data := json2.decode[map[string]json2.Any](turn.events[0]) or { panic(err) }
	outcome := if value := data['outcome'] { value as string } else { '' }
	summary := if value := data['error'] { value as string } else { '' }
	return outcome, summary
}

fn test_applied_edit_then_expired_shell_approval_is_not_a_generic_failure() {
	if !outcome_node_available() {
		eprintln('skip: node unavailable for fake-claude-outcomes fixture')
		return
	}
	turn := run_outcome_turn('apply-then-expire', ['Edit'])
	// The edit really was applied by the approved CLI tool call.
	assert turn.applied.contains('a + b')
	outcome, summary := outcome_of(turn)
	assert outcome == 'completed_with_denials', 'outcome=${outcome} events=${turn.events}'
	assert summary.contains('Edit math.js'), summary
	assert summary.contains('expired'), summary
	assert summary.contains('not verified'), summary
	assert !summary.contains('The assistant turn failed'), summary
}

fn test_applied_edit_then_cli_crash_is_partial_not_failed() {
	if !outcome_node_available() {
		return
	}
	turn := run_outcome_turn('apply-then-crash', ['Edit'])
	assert turn.applied.contains('a + b')
	outcome, summary := outcome_of(turn)
	assert outcome == 'partial', 'outcome=${outcome} events=${turn.events}'
	assert summary.contains('Edit math.js'), summary
	assert summary.contains('not verified'), summary
}

fn test_denied_approval_without_side_effects_says_nothing_was_applied() {
	if !outcome_node_available() {
		return
	}
	turn := run_outcome_turn('deny-only', [])
	assert turn.applied.contains('a - b')
	outcome, summary := outcome_of(turn)
	assert outcome == 'completed_with_denials', 'outcome=${outcome} events=${turn.events}'
	assert summary.contains('No changes were applied'), summary
}

fn test_clean_completion_with_applied_edit_is_not_presented_as_verified() {
	if !outcome_node_available() {
		return
	}
	turn := run_outcome_turn('apply-only', ['Edit'])
	assert turn.applied.contains('a + b')
	outcome, summary := outcome_of(turn)
	assert outcome == 'completed', 'outcome=${outcome} events=${turn.events}'
	assert summary.contains('not verified'), summary
}

// The API rejects every unauthenticated request; HTTP fixtures install this
// known token and send it like any real client.
fn outcome_test_install_token() {
	api_auth_state().configure('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', '', true)
}
