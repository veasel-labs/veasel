module main

import x.json2

// Installed-CLI adapter (Claude Code), first slice for #691: pure parsing
// of the `claude -p --output-format stream-json` NDJSON protocol plus argv
// construction. Protocol reference (copied verbatim, do not edit):
// tests/focus_reference/claude.ts and testing/fake-claude.mjs in PR #697,
// measured against claude 2.1.322 in agent-toolkit. Process spawning,
// approvals round-trip and session wiring land in follow-up slices; this
// file owns no I/O so it is fixture-testable without a paid provider.

pub struct ClaudeCliEvent {
pub:
	kind              string // init|text_delta|assistant_text|tool_use|approval_request|result|other
	session_id        string
	model             string
	text              string
	tool_id           string
	tool_name         string
	request_id        string
	outcome           string // completed|failed (result only)
	usage             ProviderUsage
	usage_reported    bool
	reported_cost_usd ?f64
}

fn claude_cli_string(values map[string]json2.Any, key string) string {
	if value := values[key] {
		if value is string {
			return value
		}
	}
	return ''
}

fn claude_cli_map(values map[string]json2.Any, key string) map[string]json2.Any {
	if value := values[key] {
		if value is map[string]json2.Any {
			return value
		}
	}
	return map[string]json2.Any{}
}

fn claude_cli_i64(values map[string]json2.Any, key string) i64 {
	return i64(provider_usage_amount_from_map(values, key) or { 0 })
}

// parse_claude_cli_line maps one NDJSON line to a canonical event.
// Malformed lines and unknown frames become kind 'other', never errors:
// a provider protocol drift must not crash the session loop.
pub fn parse_claude_cli_line(line string) ClaudeCliEvent {
	trimmed := line.trim_space()
	if trimmed.len == 0 {
		return ClaudeCliEvent{
			kind: 'other'
		}
	}
	frame := json2.decode[map[string]json2.Any](trimmed) or {
		return ClaudeCliEvent{
			kind: 'other'
		}
	}
	frame_type := claude_cli_string(frame, 'type')
	match frame_type {
		'system' {
			if claude_cli_string(frame, 'subtype') == 'init' {
				return ClaudeCliEvent{
					kind:       'init'
					session_id: claude_cli_string(frame, 'session_id')
					model:      claude_cli_string(frame, 'model')
				}
			}
		}
		'stream_event' {
			event := claude_cli_map(frame, 'event')
			if claude_cli_string(event, 'type') == 'content_block_delta' {
				delta := claude_cli_map(event, 'delta')
				if claude_cli_string(delta, 'type') == 'text_delta' {
					return ClaudeCliEvent{
						kind: 'text_delta'
						text: claude_cli_string(delta, 'text')
					}
				}
			}
		}
		'assistant' {
			message := claude_cli_map(frame, 'message')
			if content := message['content'] {
				if content is []json2.Any {
					mut text_parts := []string{}
					for entry in content {
						if entry is map[string]json2.Any {
							if claude_cli_string(entry, 'type') == 'tool_use' {
								return ClaudeCliEvent{
									kind:      'tool_use'
									tool_id:   claude_cli_string(entry, 'id')
									tool_name: claude_cli_string(entry, 'name')
								}
							}
							if claude_cli_string(entry, 'type') == 'text' {
								text_parts << claude_cli_string(entry, 'text')
							}
						}
					}
					// Without --include-partial-messages the final text
					// only exists here (verified against claude 2.1.325).
					if text_parts.len > 0 {
						return ClaudeCliEvent{
							kind: 'assistant_text'
							text: text_parts.join('')
						}
					}
				}
			}
		}
		'control_request' {
			request := claude_cli_map(frame, 'request')
			if claude_cli_string(request, 'subtype') == 'can_use_tool' {
				return ClaudeCliEvent{
					kind:       'approval_request'
					request_id: claude_cli_string(frame, 'request_id')
					tool_name:  claude_cli_string(request, 'tool_name')
				}
			}
		}
		'result' {
			failed := claude_cli_string(frame, 'subtype') != 'success'
			mut event := ClaudeCliEvent{
				kind:       'result'
				session_id: claude_cli_string(frame, 'session_id')
				outcome:    if failed { 'failed' } else { 'completed' }
				text:       claude_cli_string(frame, 'result')
			}
			if _ := frame['usage'] {
				usage := claude_cli_map(frame, 'usage')
				// Truthfulness (ADR-0001): usage is adapter-reported CLI
				// data. Claude reports input excluding cache creation, so
				// billable input adds it back (mirrors the TS reference);
				// cost stays separate and is session-cumulative upstream.
				event = ClaudeCliEvent{
					...event
					usage_reported:    true
					reported_cost_usd: provider_usage_amount_from_map(frame,
						'total_cost_usd')
					usage:             ProviderUsage{
						input_tokens:          claude_cli_i64(usage, 'input_tokens') +
							claude_cli_i64(usage, 'cache_creation_input_tokens')
						output_tokens:         claude_cli_i64(usage, 'output_tokens')
						cache_read_tokens:     claude_cli_i64(usage, 'cache_read_input_tokens')
						cache_creation_tokens: claude_cli_i64(usage,
							'cache_creation_input_tokens')
						cache_reported:        'cache_read_input_tokens' in usage
							|| 'cache_creation_input_tokens' in usage
						reported:              true
					}
				}
			}
			return event
		}
		else {}
	}
	return ClaudeCliEvent{
		kind: 'other'
	}
}

// claude_permission_mode_arg maps Veasel permission modes to the CLI flag
// value. Unknown modes fail closed to 'default' (always ask).
pub fn claude_permission_mode_arg(mode string) string {
	return match mode {
		'accept-edits' { 'acceptEdits' }
		'plan' { 'plan' }
		'bypass' { 'bypassPermissions' }
		else { 'default' }
	}
}

// is_safe_claude_session_id guards --resume against argv injection: the id
// is passed as a separate argv element, but reject anything that could be
// re-interpreted as a flag or path (mirrors the TS reference guard).
pub fn is_safe_claude_session_id(id string) bool {
	if id.len == 0 || id.len > 128 || id.starts_with('-') {
		return false
	}
	for ch in id {
		if !(ch.is_alnum() || ch in [`-`, `_`, `.`]) {
			return false
		}
	}
	return true
}

// claude_cli_args builds argv (without the binary name) for a headless
// stream-json session. Resume is only added for a safe provider session id.
pub fn claude_cli_args(permission_mode string, resume_session_id string) []string {
	mut args := [
		'-p',
		'--output-format',
		'stream-json',
		'--input-format',
		'stream-json',
		'--verbose',
		'--include-partial-messages',
		'--permission-prompt-tool',
		'stdio',
		'--permission-mode',
		claude_permission_mode_arg(permission_mode),
	]
	if is_safe_claude_session_id(resume_session_id) {
		args << '--resume'
		args << resume_session_id
	}
	return args
}
