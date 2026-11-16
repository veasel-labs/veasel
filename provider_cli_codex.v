module main

import x.json2

// Installed-CLI adapter (Codex), first slice for #691: pure parsing of the
// `codex app-server` JSON-RPC protocol plus policy mapping. Protocol
// reference (copied verbatim, do not edit): tests/focus_reference/codex.ts
// and testing/fake-codex.mjs in PR #697, measured against codex-cli
// 0.167.2 in agent-toolkit. Process spawning and approval round-trips
// land in follow-up slices; this file owns no I/O.

pub struct CodexCliEvent {
pub:
	kind       string // text_delta|reasoning_delta|assistant_text|turn_started|turn_completed|approval_request|user_input_request|usage_not_published|other
	thread_id  string
	turn_id    string
	item_id    string
	text       string
	request_id string
	outcome    string // completed|failed|interrupted (turn_completed only)
}

pub struct CodexPolicy {
pub:
	approval_policy string
	sandbox         string
}

// codex_policy maps Veasel permission modes onto Codex's two dials.
// Unknown modes fail closed to ask/read-only (mirrors CODEX_POLICY in the
// TS reference; `untrusted` is never used: it asked before every read).
pub fn codex_policy(mode string) CodexPolicy {
	return match mode {
		'accept-edits' {
			CodexPolicy{
				approval_policy: 'on-request'
				sandbox:         'workspace-write'
			}
		}
		'plan' {
			CodexPolicy{
				approval_policy: 'never'
				sandbox:         'read-only'
			}
		}
		'bypass' {
			CodexPolicy{
				approval_policy: 'never'
				sandbox:         'danger-full-access'
			}
		}
		else {
			CodexPolicy{
				approval_policy: 'on-request'
				sandbox:         'read-only'
			}
		}
	}
}

fn codex_cli_string(values map[string]json2.Any, key string) string {
	if value := values[key] {
		if value is string {
			return value
		}
	}
	return ''
}

fn codex_cli_map(values map[string]json2.Any, key string) map[string]json2.Any {
	if value := values[key] {
		if value is map[string]json2.Any {
			return value
		}
	}
	return map[string]json2.Any{}
}

// parse_codex_cli_line maps one JSON-RPC line for the given parent thread
// to a canonical event. Frames for other (child/native-agent) threads and
// malformed lines become kind 'other': child output must never leak into
// the parent session journal. Codex token-usage notifications are
// explicitly NOT published as usage: upstream `last` is active context
// and `total` is thread-cumulative, neither is a per-turn delta, so the
// adapter returns usage_not_published and usage stays unreported.
pub fn parse_codex_cli_line(line string, parent_thread_id string) CodexCliEvent {
	trimmed := line.trim_space()
	if trimmed.len == 0 {
		return CodexCliEvent{
			kind: 'other'
		}
	}
	frame := json2.decode[map[string]json2.Any](trimmed) or {
		return CodexCliEvent{
			kind: 'other'
		}
	}
	params := codex_cli_map(frame, 'params')
	thread_id := codex_cli_string(params, 'threadId')
	if thread_id.len > 0 && parent_thread_id.len > 0 && thread_id != parent_thread_id {
		return CodexCliEvent{
			kind: 'other'
		}
	}
	method := codex_cli_string(frame, 'method')
	turn := codex_cli_map(params, 'turn')
	event := CodexCliEvent{
		thread_id:  thread_id
		turn_id:    codex_cli_string(params, 'turnId')
		item_id:    codex_cli_string(params, 'itemId')
		request_id: codex_cli_string(frame, 'id')
	}
	match method {
		'item/agentMessage/delta' {
			return CodexCliEvent{
				...event
				kind: 'text_delta'
				text: codex_cli_string(params, 'delta')
			}
		}
		'item/reasoning/summaryTextDelta', 'item/reasoning/textDelta' {
			return CodexCliEvent{
				...event
				kind: 'reasoning_delta'
				text: codex_cli_string(params, 'delta')
			}
		}
		'turn/started' {
			return CodexCliEvent{
				...event
				kind:    'turn_started'
				turn_id: codex_cli_string(turn, 'id')
			}
		}
		'turn/completed' {
			status := codex_cli_string(turn, 'status')
			return CodexCliEvent{
				...event
				kind:    'turn_completed'
				turn_id: codex_cli_string(turn, 'id')
				outcome: match status {
					'completed' { 'completed' }
					'interrupted' { 'interrupted' }
					else { 'failed' }
				}
			}
		}
		'item/commandExecution/requestApproval', 'item/fileChange/requestApproval',
		'execCommandApproval', 'applyPatchApproval' {
			return CodexCliEvent{
				...event
				kind: 'approval_request'
			}
		}
		'item/completed' {
			// Final agent text fallback for turns that emit no deltas.
			item := codex_cli_map(params, 'item')
			if codex_cli_string(item, 'type') == 'agentMessage' {
				return CodexCliEvent{
					...event
					kind: 'assistant_text'
					text: codex_cli_string(item, 'text')
				}
			}
			return CodexCliEvent{
				kind: 'other'
			}
		}
		'item/tool/requestUserInput' {
			return CodexCliEvent{
				...event
				kind: 'user_input_request'
			}
		}
		'thread/tokenUsage/updated' {
			return CodexCliEvent{
				...event
				kind: 'usage_not_published'
			}
		}
		else {
			return CodexCliEvent{
				kind: 'other'
			}
		}
	}
}
