module main

import os
import time
import x.json2

// Installed-CLI session runner (Codex), wiring slice for #691: spawns
// `codex app-server` and speaks its JSON-RPC protocol, reducing frames
// with parse_codex_cli_line (copied-reference protocol: tests/
// focus_reference/codex.ts, measured codex-cli 0.167.2; host has 0.169.0).
// Approvals are NEVER auto-approved: each server approval request is
// decided by the caller's decider, denied by default (fail closed), and
// never widened beyond the decisions the server itself offered. Codex
// token-usage notifications are not published as per-turn usage.

pub struct CodexCliTurnResult {
pub:
	events             []CodexCliEvent
	text               string
	outcome            string // completed|failed|interrupted
	thread_id          string
	model              string
	usage_reported     bool // always false: Codex publishes no per-turn usage
	approvals_denied   int
	approvals_approved int
}

// codex_deny_decision picks the fail-closed denial the server offered:
// 'decline' normally, 'cancel' when decline is not offered.
pub fn codex_deny_decision(available []string) string {
	if available.len == 0 || 'decline' in available {
		return 'decline'
	}
	if 'cancel' in available {
		return 'cancel'
	}
	return 'decline'
}

fn codex_available_decisions(params map[string]json2.Any) []string {
	mut decisions := []string{}
	if raw := params['availableDecisions'] {
		if raw is []json2.Any {
			for entry in raw {
				if entry is string {
					decisions << entry
				}
			}
		}
	}
	return decisions
}

fn codex_frame_id_json(frame map[string]json2.Any) string {
	if raw := frame['id'] {
		return json2.encode(raw)
	}
	return 'null'
}

fn codex_rpc_request(id int, method string, params string) string {
	return '{"id":${id},"method":"${method}","params":${params}}'
}

// run_codex_cli_turn runs one user turn to its turn/completed frame.
// Returns an error only for spawn/timeout/transport failures;
// provider-reported turn failure is outcome='failed'.
pub fn run_codex_cli_turn(command string, cwd string, permission_mode string,
	model string, user_text string, timeout_ms int, on_text_delta ProviderTextDeltaFn,
	decide CliApprovalDecisionFn) !CodexCliTurnResult {
	mut process := os.new_process(command)
	process.set_args(['app-server'])
	if cwd.len > 0 {
		process.set_work_folder(cwd)
	}
	process.set_redirect_stdio()
	process.run()
	if process.status != .running {
		process.close()
		return error('unable to start installed CLI: ${command}')
	}
	defer {
		if process.is_alive() {
			process.signal_term()
			for _ in 0 .. 20 {
				if !process.is_alive() {
					break
				}
				time.sleep(10 * time.millisecond)
			}
			if process.is_alive() {
				process.signal_kill()
			}
		}
		process.close()
	}
	policy := codex_policy(permission_mode)
	timeout := if timeout_ms > 0 { timeout_ms } else { 120_000 }
	started := time.now()
	process.stdin_write(codex_rpc_request(1, 'initialize',
		'{"clientInfo":{"name":"veasel","title":"Veasel","version":"1"},"capabilities":{"experimentalApi":${permission_mode == 'plan'}}}') +
		'\n')

	mut events := []CodexCliEvent{}
	mut text := ''
	mut fallback_text := ''
	mut thread_id := ''
	mut turn_id := ''
	mut resolved_model := model
	mut approvals_denied := 0
	mut approvals_approved := 0
	mut phase := 0 // 0=initialize, 1=thread/start, 2=turn/start, 3=streaming
	mut buffer := ''
	for {
		if time.since(started).milliseconds() > timeout {
			return error('installed CLI turn timed out after ${timeout}ms')
		}
		if process.is_pending(.stdout) {
			buffer += process.stdout_read()
			for {
				newline := buffer.index('\n') or { break }
				line := buffer[..newline]
				buffer = buffer[newline + 1..]
				trimmed := line.trim_space()
				if trimmed.len == 0 {
					continue
				}
				frame := json2.decode[map[string]json2.Any](trimmed) or { continue }
				method := codex_cli_string(frame, 'method')
				params := codex_cli_map(frame, 'params')
				// JSON-RPC responses to our own requests drive the handshake.
				if method.len == 0 {
					result := codex_cli_map(frame, 'result')
					if 'error' in frame {
						err_obj := codex_cli_map(frame, 'error')
						return error('installed CLI request failed: ${codex_cli_string(err_obj, 'message')}')
					}
					if phase == 0 {
						process.stdin_write('{"method":"initialized"}\n')
						model_json := if model.len > 0 { json2.encode(model) } else { 'null' }
						thread_params := '{"cwd":${json2.encode(cwd)},"approvalPolicy":"${policy.approval_policy}","approvalsReviewer":"user","sandbox":"${policy.sandbox}","model":${model_json}}'
						process.stdin_write(codex_rpc_request(2, 'thread/start',
							thread_params) + '\n')
						phase = 1
					} else if phase == 1 {
						thread_obj := codex_cli_map(result, 'thread')
						thread_id = codex_cli_string(thread_obj, 'id')
						if thread_id.len == 0 {
							return error('installed CLI did not return a thread')
						}
						reported_model := codex_cli_string(result, 'model')
						if reported_model.len > 0 {
							resolved_model = reported_model
						}
						turn_params := '{"threadId":${json2.encode(thread_id)},"input":[{"type":"text","text":${json2.encode(user_text)},"text_elements":[]}]}'
						process.stdin_write(codex_rpc_request(3, 'turn/start',
							turn_params) + '\n')
						phase = 2
					} else if phase == 2 {
						turn_obj := codex_cli_map(result, 'turn')
						turn_id = codex_cli_string(turn_obj, 'id')
						phase = 3
					}
					continue
				}
				// Server approval/input requests for OTHER threads or a
				// stale turn are never answered and never counted.
				frame_thread := codex_cli_string(params, 'threadId')
				frame_turn := codex_cli_string(params, 'turnId')
				in_scope := (frame_thread.len == 0 || frame_thread == thread_id)
					&& (frame_turn.len == 0 || turn_id.len == 0 || frame_turn == turn_id)
				event := parse_codex_cli_line(trimmed, thread_id)
				events << event
				if method in ['item/commandExecution/requestApproval', 'item/fileChange/requestApproval',
					'execCommandApproval', 'applyPatchApproval'] {
					if in_scope && phase == 3 {
						request_id := 'codex-${codex_frame_id_json(frame).trim('"')}'
						tool_name := method.all_after_last('/')
						input_json := json2.encode(params)
						if decide(request_id, tool_name, input_json) {
							available := codex_available_decisions(params)
							if available.len == 0 || 'accept' in available {
								process.stdin_write('{"id":${codex_frame_id_json(frame)},"result":{"decision":"accept"}}' +
									'\n')
								approvals_approved += 1
							} else {
								process.stdin_write('{"id":${codex_frame_id_json(frame)},"result":{"decision":"${codex_deny_decision(available)}"}}' +
									'\n')
								approvals_denied += 1
							}
						} else {
							process.stdin_write('{"id":${codex_frame_id_json(frame)},"result":{"decision":"${codex_deny_decision(codex_available_decisions(params))}"}}' +
								'\n')
							approvals_denied += 1
						}
					}
					continue
				}
				if method == 'item/tool/requestUserInput' {
					if in_scope && phase == 3 {
						// Fail closed: never invent user answers.
						process.stdin_write('{"id":${codex_frame_id_json(frame)},"error":{"code":-32000,"message":"Veasel does not answer interactive questions in this runner"}}' +
							'\n')
						approvals_denied += 1
					}
					continue
				}
				match event.kind {
					'text_delta' {
						text += event.text
						on_text_delta(event.text) or {}
					}
					'assistant_text' {
						fallback_text = event.text
					}
					'turn_completed' {
						if frame_thread == thread_id && (turn_id.len == 0
							|| event.turn_id.len == 0 || event.turn_id == turn_id) {
							return CodexCliTurnResult{
								events:             events
								text:               if text.len > 0 {
									text
								} else {
									fallback_text
								}
								outcome:            event.outcome
								thread_id:          thread_id
								model:              resolved_model
								usage_reported:     false
								approvals_denied:   approvals_denied
								approvals_approved: approvals_approved
							}
						}
					}
					else {}
				}
			}
			continue
		}
		if !process.is_alive() {
			return error('installed CLI exited before a turn/completed frame')
		}
		time.sleep(5 * time.millisecond)
	}
	return error('installed CLI turn ended without a turn/completed frame')
}
