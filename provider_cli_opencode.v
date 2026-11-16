module main

import x.json2

// Installed-CLI adapter (OpenCode ACP), first slice for #691: pure parsing
// of the `opencode acp` (ACP v1) JSON-RPC protocol. Protocol reference
// (copied verbatim, do not edit): tests/focus_reference/opencode.ts and
// testing/fake-opencode.mjs in PR #697. Process spawning, permission
// round-trips and session/load wiring land in follow-up slices; this file
// owns no I/O.

pub struct OpencodeCliEvent {
pub:
	kind           string // text_delta|reasoning_delta|tool_call|tool_update|approval_request|approval_unsafe|other
	session_id     string
	text           string
	tool_id        string
	request_id     string
	can_allow_once bool
}

pub struct OpencodePromptOutcome {
pub:
	outcome        string // completed|failed|interrupted
	usage_reported bool
	usage          ProviderUsage
}

// opencode_permission_mode_supported: ACP request_permission has no
// session-scoped grant in Veasel's model (allow-session is rejected by the
// TS reference, canAllowForSession:false), so only explicit ask mode is
// supported; anything else must fail closed before launch (#638).
pub fn opencode_permission_mode_supported(mode string) bool {
	return mode == 'ask'
}

fn opencode_cli_string(values map[string]json2.Any, key string) string {
	if value := values[key] {
		if value is string {
			return value
		}
	}
	return ''
}

fn opencode_cli_map(values map[string]json2.Any, key string) map[string]json2.Any {
	if value := values[key] {
		if value is map[string]json2.Any {
			return value
		}
	}
	return map[string]json2.Any{}
}

fn opencode_cli_i64(values map[string]json2.Any, key string) i64 {
	if value := values[key] {
		match value {
			i8, i16, i32, int, i64, u8, u16, u32, u64, f32, f64 { return i64(value) }
			else { return 0 }
		}
	}
	return 0
}

// parse_opencode_cli_line maps one ACP JSON-RPC line for the given session
// to a canonical event. Frames for other sessions (including OpenCode
// child sessions) and malformed lines become kind 'other'. A permission
// request without BOTH allow_once and reject_once options is
// approval_unsafe: the caller must answer outcome cancelled, because an
// approval that cannot be rejected must never be displayed as approvable.
pub fn parse_opencode_cli_line(line string, session_id string) OpencodeCliEvent {
	trimmed := line.trim_space()
	if trimmed.len == 0 {
		return OpencodeCliEvent{
			kind: 'other'
		}
	}
	frame := json2.decode[map[string]json2.Any](trimmed) or {
		return OpencodeCliEvent{
			kind: 'other'
		}
	}
	params := opencode_cli_map(frame, 'params')
	frame_session := opencode_cli_string(params, 'sessionId')
	if frame_session.len > 0 && session_id.len > 0 && frame_session != session_id {
		return OpencodeCliEvent{
			kind: 'other'
		}
	}
	method := opencode_cli_string(frame, 'method')
	match method {
		'session/update' {
			update := opencode_cli_map(params, 'update')
			update_kind := opencode_cli_string(update, 'sessionUpdate')
			match update_kind {
				'agent_message_chunk', 'agent_thought_chunk' {
					content := opencode_cli_map(update, 'content')
					return OpencodeCliEvent{
						kind:       if update_kind == 'agent_message_chunk' {
							'text_delta'
						} else {
							'reasoning_delta'
						}
						session_id: frame_session
						text:       opencode_cli_string(content, 'text')
					}
				}
				'tool_call', 'tool_call_update' {
					return OpencodeCliEvent{
						kind:       if update_kind == 'tool_call' {
							'tool_call'
						} else {
							'tool_update'
						}
						session_id: frame_session
						tool_id:    opencode_cli_string(update, 'toolCallId')
					}
				}
				else {
					return OpencodeCliEvent{
						kind: 'other'
					}
				}
			}
		}
		'session/request_permission' {
			mut has_allow_once := false
			mut has_reject_once := false
			if options := params['options'] {
				if options is []json2.Any {
					for entry in options {
						if entry is map[string]json2.Any {
							match opencode_cli_string(entry, 'kind') {
								'allow_once' { has_allow_once = true }
								'reject_once' { has_reject_once = true }
								else {}
							}
						}
					}
				}
			}
			tool_call := opencode_cli_map(params, 'toolCall')
			if has_allow_once && has_reject_once {
				return OpencodeCliEvent{
					kind:           'approval_request'
					session_id:     frame_session
					tool_id:        opencode_cli_string(tool_call, 'toolCallId')
					request_id:     opencode_cli_string(frame, 'id')
					can_allow_once: true
				}
			}
			return OpencodeCliEvent{
				kind:       'approval_unsafe'
				session_id: frame_session
				request_id: opencode_cli_string(frame, 'id')
			}
		}
		else {
			return OpencodeCliEvent{
				kind: 'other'
			}
		}
	}
}

// parse_opencode_prompt_result maps an ACP session/prompt result to a turn
// outcome. Usage is adapter-reported only: input/output tokens when the
// result carries a usage object, cost always unreported (the CLI reports
// none) — never estimated (ADR-0001).
pub fn parse_opencode_prompt_result(result map[string]json2.Any) OpencodePromptOutcome {
	stop_reason := opencode_cli_string(result, 'stopReason')
	mut outcome := OpencodePromptOutcome{
		outcome: match stop_reason {
			'cancelled' { 'interrupted' }
			'end_turn', 'refusal' { 'completed' }
			'' { 'completed' }
			else { 'failed' }
		}
	}
	if _ := result['usage'] {
		usage := opencode_cli_map(result, 'usage')
		outcome = OpencodePromptOutcome{
			...outcome
			usage_reported: true
			usage:          ProviderUsage{
				input_tokens:  opencode_cli_i64(usage, 'inputTokens')
				output_tokens: opencode_cli_i64(usage, 'outputTokens')
				reported:      true
			}
		}
	}
	return outcome
}
