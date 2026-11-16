module main

import os
import time
import x.json2

// Installed-CLI session runner (OpenCode ACP), wiring slice for #691:
// spawns `opencode acp` and speaks ACP v1 JSON-RPC (initialize,
// session/new, session/prompt), reducing notifications with
// parse_opencode_cli_line (copied-reference protocol:
// tests/focus_reference/opencode.ts). Permission requests are decided by
// the caller's decider and denied by default; a request that cannot be
// rejected (approval_unsafe) is answered cancelled, never displayed as
// approvable. Elicitation questions are declined — no invented answers.
// Usage is adapter-reported prompt tokens only; cost is never reported.

pub struct OpencodeCliTurnResult {
pub:
	events             []OpencodeCliEvent
	text               string
	outcome            string // completed|failed|interrupted
	session_id         string
	usage              ProviderUsage
	usage_reported     bool
	approvals_denied   int
	approvals_approved int
}

fn opencode_option_id(params map[string]json2.Any, kind string) string {
	if options := params['options'] {
		if options is []json2.Any {
			for entry in options {
				if entry is map[string]json2.Any {
					if opencode_cli_string(entry, 'kind') == kind {
						return opencode_cli_string(entry, 'optionId')
					}
				}
			}
		}
	}
	return ''
}

fn opencode_frame_id_json(frame map[string]json2.Any) string {
	if raw := frame['id'] {
		return json2.encode(raw)
	}
	return 'null'
}

fn opencode_rpc(id int, method string, params string) string {
	return '{"jsonrpc":"2.0","id":${id},"method":"${method}","params":${params}}'
}

// run_opencode_cli_turn runs one prompt to its session/prompt result.
// Returns an error only for spawn/timeout/transport failures;
// provider-reported failure is outcome='failed'.
pub fn run_opencode_cli_turn(command string, cwd string, model string,
	user_text string, timeout_ms int, on_text_delta ProviderTextDeltaFn,
	decide CliApprovalDecisionFn) !OpencodeCliTurnResult {
	mut process := os.new_process(command)
	process.set_args(['acp'])
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
	timeout := if timeout_ms > 0 { timeout_ms } else { 120_000 }
	started := time.now()
	process.stdin_write(opencode_rpc(1, 'initialize',
		'{"protocolVersion":1,"clientInfo":{"name":"veasel","version":"1"},"clientCapabilities":{}}') +
		'\n')

	mut events := []OpencodeCliEvent{}
	mut text := ''
	mut session_id := ''
	mut approvals_denied := 0
	mut approvals_approved := 0
	mut phase := 0 // 0=initialize, 1=session/new, 2=config, 3=prompt
	prompt_rpc_id := if model.len > 0 { 4 } else { 3 }
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
				method := opencode_cli_string(frame, 'method')
				params := opencode_cli_map(frame, 'params')
				// Responses to our requests (no method) drive the handshake
				// and the final prompt result.
				if method.len == 0 {
					if 'error' in frame {
						err_obj := opencode_cli_map(frame, 'error')
						return error('installed CLI request failed: ${opencode_cli_string(err_obj, 'message')}')
					}
					result := opencode_cli_map(frame, 'result')
					if phase == 0 {
						process.stdin_write('{"jsonrpc":"2.0","method":"initialized","params":{}}' + '\n')
						process.stdin_write(opencode_rpc(2, 'session/new',
							'{"cwd":${json2.encode(cwd)},"mcpServers":[]}') + '\n')
						phase = 1
					} else if phase == 1 {
						session_id = opencode_cli_string(result, 'sessionId')
						if session_id.len == 0 {
							return error('installed CLI did not return a session')
						}
						if model.len > 0 {
							process.stdin_write(opencode_rpc(3, 'session/set_config_option',
								'{"sessionId":${json2.encode(session_id)},"configId":"model","value":${json2.encode(model)}}') +
								'\n')
							phase = 2
						} else {
							process.stdin_write(opencode_rpc(prompt_rpc_id, 'session/prompt',
								'{"sessionId":${json2.encode(session_id)},"prompt":[{"type":"text","text":${json2.encode(user_text)}}]}') +
								'\n')
							phase = 3
						}
					} else if phase == 2 {
						process.stdin_write(opencode_rpc(prompt_rpc_id, 'session/prompt',
							'{"sessionId":${json2.encode(session_id)},"prompt":[{"type":"text","text":${json2.encode(user_text)}}]}') +
							'\n')
						phase = 3
					} else if phase == 3 {
						outcome := parse_opencode_prompt_result(result)
						return OpencodeCliTurnResult{
							events:             events
							text:               text
							outcome:            outcome.outcome
							session_id:         session_id
							usage:              outcome.usage
							usage_reported:     outcome.usage_reported
							approvals_denied:   approvals_denied
							approvals_approved: approvals_approved
						}
					}
					continue
				}
				event := parse_opencode_cli_line(trimmed, session_id)
				events << event
				if method == 'session/request_permission' {
					id_json := opencode_frame_id_json(frame)
					if event.kind == 'approval_unsafe' {
						// Cannot be rejected safely: cancel, never approve.
						process.stdin_write('{"jsonrpc":"2.0","id":${id_json},"result":{"outcome":{"outcome":"cancelled"}}}' +
							'\n')
						approvals_denied += 1
					} else if event.kind == 'approval_request' {
						tool_call := opencode_cli_map(params, 'toolCall')
						tool_name := opencode_cli_string(tool_call, 'name')
						input_json := json2.encode(opencode_cli_map(tool_call, 'rawInput'))
						request_id := 'opencode-${event.request_id}'
						if decide(request_id, tool_name, input_json) {
							option_id := opencode_option_id(params, 'allow_once')
							process.stdin_write('{"jsonrpc":"2.0","id":${id_json},"result":{"outcome":{"outcome":"selected","optionId":${json2.encode(option_id)}}}}' +
								'\n')
							approvals_approved += 1
						} else {
							option_id := opencode_option_id(params, 'reject_once')
							process.stdin_write('{"jsonrpc":"2.0","id":${id_json},"result":{"outcome":{"outcome":"selected","optionId":${json2.encode(option_id)}}}}' +
								'\n')
							approvals_denied += 1
						}
					}
					continue
				}
				if method != 'session/update' && 'id' in frame {
					// Any other server request (e.g. elicitation): fail
					// closed, never invent user input.
					id_json := opencode_frame_id_json(frame)
					if method == 'elicitation/create' {
						process.stdin_write('{"jsonrpc":"2.0","id":${id_json},"result":{"action":"decline"}}' +
							'\n')
					} else {
						process.stdin_write('{"jsonrpc":"2.0","id":${id_json},"error":{"code":-32601,"message":"Veasel does not implement this ACP client method"}}' +
							'\n')
					}
					continue
				}
				if event.kind == 'text_delta' {
					text += event.text
					on_text_delta(event.text) or {}
				}
			}
			continue
		}
		if !process.is_alive() {
			return error('installed CLI exited before a prompt result')
		}
		time.sleep(5 * time.millisecond)
	}
	return error('installed CLI turn ended without a prompt result')
}
