module main

import os
import time
import x.json2

// Installed-CLI session runner (Claude Code), wiring slice for #691:
// spawns the CLI with the argv from provider_cli_claude.v, speaks
// stream-json over stdio, and reduces frames with parse_claude_cli_line.
// Approvals are NEVER auto-approved in this layer: every can_use_tool
// request is denied in-band (fail closed) and surfaced in the returned
// events so a future UI/API layer can own the decision. Cancellation is
// the operation cancel context (CliCancelFn), which kills the CLI's whole
// process group; timeout does the same.

// CliApprovalDecisionFn decides ONE tool approval. Returning false (or
// the absence of an interactive decider) denies the tool: fail closed.
pub type CliApprovalDecisionFn = fn (request_id string, tool_name string, input_json string) bool

pub fn deny_all_cli_approvals(_ string, _ string, _ string) bool {
	return false
}

pub struct ProviderCliTurnResult {
pub:
	events             []ClaudeCliEvent
	text               string
	outcome            string // completed|failed|interrupted
	session_id         string
	model              string
	usage              ProviderUsage
	usage_reported     bool
	reported_cost_usd  ?f64
	approvals_denied   int
	approvals_approved int
}

struct ClaudeCliUserContent {
pub:
	typ  string @[json: 'type']
	text string
}

struct ClaudeCliUserMessageBody {
pub:
	role    string
	content []ClaudeCliUserContent
}

struct ClaudeCliUserMessage {
pub:
	typ                string @[json: 'type']
	message            ClaudeCliUserMessageBody
	parent_tool_use_id ?string
	session_id         string
}

struct ClaudeCliDenyResponse {
pub:
	behavior string
	message  string
}

struct ClaudeCliControlResponseBody {
pub:
	subtype    string
	request_id string
	response   ClaudeCliDenyResponse
}

struct ClaudeCliControlResponse {
pub:
	typ      string @[json: 'type']
	response ClaudeCliControlResponseBody
}

struct ClaudeCliInitRequest {
pub:
	subtype string
	hooks   ?string
}

struct ClaudeCliInit {
pub:
	typ        string @[json: 'type']
	request_id string
	request    ClaudeCliInitRequest
}

// run_claude_cli_turn runs one user turn to its result frame.
// command is the CLI executable (PATH-resolved by the OS), args are built
// by claude_cli_args. Returns an error only for spawn/timeout/protocol
// transport failures; provider-reported failures are outcome='failed'.
pub fn run_claude_cli_turn(command string, cwd string, permission_mode string,
	resume_session_id string, user_text string, timeout_ms int,
	on_text_delta ProviderTextDeltaFn, decide CliApprovalDecisionFn) !ProviderCliTurnResult {
	return run_claude_cli_turn_observed(command, cwd, permission_mode, resume_session_id,
		user_text, timeout_ms, on_text_delta, decide, unsafe { nil }, unsafe { nil })
}

// run_claude_cli_turn_observed is run_claude_cli_turn that also records the
// tool calls and results the CLI reports into facts (nil disables it). The
// facts survive a transport error, so a turn that dies after applying an edit
// still knows what it applied.
pub fn run_claude_cli_turn_observed(command string, cwd string, permission_mode string,
	resume_session_id string, user_text string, timeout_ms int,
	on_text_delta ProviderTextDeltaFn, decide CliApprovalDecisionFn, facts &TurnFacts, cancel CliCancelFn) !ProviderCliTurnResult {
	mut observed := unsafe { facts }
	if facts != unsafe { nil } {
		observed.set_effects_observed(true)
	}
	mut process := os.new_process(command)
	process.set_args(claude_cli_args(permission_mode, resume_session_id))
	if cwd.len > 0 {
		process.set_work_folder(cwd)
	}
	process.set_redirect_stdio()
	process.use_pgroup = true
	process.run()
	if process.status != .running {
		process.close()
		return error('unable to start installed CLI: ${command}')
	}
	defer {
		cli_terminate_process(mut process)
	}
	process.stdin_write(json2.encode(ClaudeCliInit{
		typ:        'control_request'
		request_id: 'veasel-init'
		request:    ClaudeCliInitRequest{
			subtype: 'initialize'
		}
	}) + '\n')
	process.stdin_write(json2.encode(ClaudeCliUserMessage{
		typ:        'user'
		message:    ClaudeCliUserMessageBody{
			role:    'user'
			content: [ClaudeCliUserContent{
				typ:  'text'
				text: user_text
			}]
		}
		session_id: resume_session_id
	}) + '\n')

	mut events := []ClaudeCliEvent{}
	mut text := ''
	mut fallback_text := ''
	mut model := ''
	mut approvals_denied := 0
	mut approvals_approved := 0
	mut buffer := ''
	started := time.now()
	timeout := if timeout_ms > 0 { timeout_ms } else { 120_000 }
	for {
		if reason := cli_cancel_reason(cancel) {
			return error(reason)
		}
		if time.since(started).milliseconds() > timeout {
			return error('installed CLI turn timed out after ${timeout}ms')
		}
		if process.is_pending(.stdout) {
			buffer += process.stdout_read()
			for {
				newline := buffer.index('\n') or { break }
				line := buffer[..newline]
				buffer = buffer[newline + 1..]
				event := parse_claude_cli_line(line)
				events << event
				if facts != unsafe { nil } {
					for tool in claude_cli_tool_uses(line) {
						observed.note_tool_use(tool.id, tool.name, tool.input_json)
					}
					for tool_result in claude_cli_tool_results(line) {
						observed.note_tool_result(tool_result.tool_id, tool_result.is_error)
					}
					if event.kind == 'approval_request' {
						observed.note_gated(event.approval_tool_id)
					}
				}
				match event.kind {
					'init' {
						model = event.model
					}
					'text_delta' {
						text += event.text
						on_text_delta(event.text) or {}
					}
					'assistant_text' {
						// Final-text fallback when the CLI emits no
						// partial deltas (verified claude 2.1.325).
						fallback_text = event.text
					}
					'approval_request' {
						if decide(event.request_id, event.tool_name, event.input_json) {
							// Explicit approval: allow with the CLI's own
							// proposed input, verbatim. Never widen it.
							process.stdin_write('{"type":"control_response","response":{"subtype":"success","request_id":"${event.request_id}","response":{"behavior":"allow","updatedInput":${event.input_json}}}}' + '\n')
							approvals_approved += 1
						} else {
							// Fail closed: deny in-band, record for the caller.
							process.stdin_write(json2.encode(ClaudeCliControlResponse{
								typ:      'control_response'
								response: ClaudeCliControlResponseBody{
									subtype:    'success'
									request_id: event.request_id
									response:   ClaudeCliDenyResponse{
										behavior: 'deny'
										message:  'Denied by Veasel policy: approvals are not auto-approved.'
									}
								}
							}) + '\n')
							approvals_denied += 1
						}
					}
					'result' {
						return ProviderCliTurnResult{
							events:             events
							text:               if text.len > 0 {
								text
							} else if fallback_text.len > 0 {
								fallback_text
							} else {
								event.text
							}
							outcome:            event.outcome
							session_id:         event.session_id
							model:              model
							usage:              event.usage
							usage_reported:     event.usage_reported
							reported_cost_usd:  event.reported_cost_usd
							approvals_denied:   approvals_denied
							approvals_approved: approvals_approved
						}
					}
					else {}
				}
			}
			continue
		}
		if !process.is_alive() {
			if resume_session_id.len > 0 {
				return error('CLI resume failed: installed CLI exited before a result frame')
			}
			return error('installed CLI exited before a result frame')
		}
		time.sleep(5 * time.millisecond)
	}
	return error('installed CLI turn ended without a result frame')
}

// cli_transcript_prompt flattens the canonical Veasel conversation into
// one prompt for a stateless CLI turn. Veasel's store stays the canonical
// history (ADR-0001): CLI session resume is an optimization for later,
// continuity never depends on the CLI's own session store.
pub fn cli_transcript_prompt(messages []ChatMessage) string {
	mut parts := []string{cap: messages.len}
	for message in messages {
		if message.content.trim_space().len == 0 {
			continue
		}
		parts << '${message.role}: ${message.content}'
	}
	return parts.join('\n\n')
}

// complete_cli_provider_turn runs one installed-CLI turn for a session
// completion request and maps it onto the canonical CompletionOutput so
// the agent loop persists content/usage exactly like an HTTP provider
// turn. The stream-json (Claude Code) and app-server (Codex) protocols
// are wired; other protocols fail closed until their runners land.
pub fn complete_cli_provider_turn(messages []ChatMessage, config ModelConfig,
	cwd string, on_text_delta ProviderTextDeltaFn) !CompletionOutput {
	return complete_cli_provider_turn_with_approvals(messages, config, cwd,
		on_text_delta, deny_all_cli_approvals)
}

pub fn complete_cli_provider_turn_with_approvals(messages []ChatMessage,
	config ModelConfig, cwd string, on_text_delta ProviderTextDeltaFn,
	decide CliApprovalDecisionFn) !CompletionOutput {
	return complete_cli_provider_turn_resumable(messages, config, cwd,
		on_text_delta, decide, '')
}

// complete_cli_provider_turn_with_resume is the session-aware entry: it
// resumes the CLI's native session for (session_id, provider) when a
// safe stored id exists, persists the id the CLI reports back, and on a
// resume failure clears the stale id and retries once with the full
// flattened canonical transcript. Veasel's history stays canonical;
// resume is only a continuation optimization.
pub fn complete_cli_provider_turn_with_resume(mut store Store, session_id string,
	messages []ChatMessage, config ModelConfig, cwd string,
	on_text_delta ProviderTextDeltaFn, decide CliApprovalDecisionFn) !CompletionOutput {
	resume_id := store.get_cli_resume_id(session_id, config.provider)
	mut streamed := &StreamedFlag{}
	wrapped := fn [mut streamed, on_text_delta] (delta string) ! {
		streamed.value = true
		on_text_delta(delta)!
	}
	output := complete_cli_provider_turn_resumable(messages, config, cwd, wrapped,
		decide, resume_id) or {
		if resume_id.len == 0 || !err.msg().starts_with('CLI resume failed') {
			return err
		}
		// Stale CLI session: clear it and retry once from the canonical
		// transcript — but never after text already streamed, so the
		// session journal cannot show a duplicated partial answer.
		store.clear_cli_resume_id(session_id, config.provider) or {}
		if streamed.value {
			return err
		}
		fresh := complete_cli_provider_turn_resumable(messages, config, cwd,
			on_text_delta, decide, '')!
		if fresh.cli_session_id.len > 0 {
			store.set_cli_resume_id(session_id, config.provider, fresh.cli_session_id) or {}
		}
		return fresh
	}
	if output.cli_session_id.len > 0 {
		store.set_cli_resume_id(session_id, config.provider, output.cli_session_id) or {}
	}
	return output
}

struct StreamedFlag {
pub mut:
	value bool
}

fn complete_cli_provider_turn_resumable(messages []ChatMessage,
	config ModelConfig, cwd string, on_text_delta ProviderTextDeltaFn,
	decide CliApprovalDecisionFn, resume_id string) !CompletionOutput {
	// Permission mode is the user's explicit session-level approval
	// choice (default 'ask': every tool approval is denied in-band by
	// the runner). 'accept-edits' means the user explicitly opted into
	// the CLI applying file edits without per-tool prompts; it is never
	// inferred. Interactive per-tool approvals replace the deny path
	// when the approval layer lands (#691 follow-up).
	permission_mode := if config.permission_mode.len > 0 {
		config.permission_mode
	} else {
		os.getenv_opt('VEASEL_CLI_PERMISSION_MODE') or { 'ask' }
	}
	spec := validate_provider_cli_launch(config.provider, permission_mode)!
	if spec.protocol !in ['stream-json', 'app-server', 'acp'] {
		return error('installed-CLI protocol ${spec.protocol} is not yet wired for session turns')
	}
	// Resuming sends only the latest user message (the CLI holds the
	// earlier context); a fresh turn sends the full flattened canonical
	// transcript. An unsafe stored id is treated as no resume.
	safe_resume_id := if is_safe_cli_session_id(resume_id) { resume_id } else { '' }
	prompt := if safe_resume_id.len > 0 {
		cli_resume_prompt(messages)
	} else {
		cli_transcript_prompt(messages)
	}
	if prompt.trim_space().len == 0 {
		return error('installed-CLI turn requires a non-empty conversation')
	}
	// Cancellation: the operation deadline bounds the CLI process. When
	// it fires, the runner kills the process (term, then kill) and the
	// turn errors instead of hanging a session worker forever.
	mut timeout_ms := 120_000
	if deadline := config.request_deadline {
		remaining := int((deadline - time.now()) / time.millisecond)
		if remaining < 1_000 {
			return error('installed CLI turn cancelled before launch (deadline exceeded)')
		}
		if remaining < timeout_ms {
			timeout_ms = remaining
		}
	}
	// Veasel's placeholder model 'default' means "the CLI's own default";
	// never forward it as a literal model id (Muse rejects it, Codex
	// would too).
	cli_model := if config.model == 'default' { '' } else { config.model }
	if spec.protocol == 'acp' {
		// OpenCode decides for itself whether to ask: without enforced ask
		// permissions in its own config it applies edits silently, so a
		// Veasel 'ask' turn must inject them (fail closed on bad config).
		acp_env := if spec.id == 'opencode' {
			opencode_ask_env()!
		} else {
			map[string]string{}
		}
		acp_turn := run_acp_cli_turn_cancellable_with_env(spec.exec, ['acp'], cwd,
			acp_session_configs(spec.id, cli_model), safe_resume_id, prompt,
			timeout_ms, on_text_delta, decide, config.cli_cancel, acp_env)!
		if acp_turn.outcome != 'completed' {
			return error('installed CLI ${spec.name} turn ${acp_turn.outcome}')
		}
		return CompletionOutput{
			provider:          config.provider
			model:             config.model
			content:           acp_turn.text
			usage:             acp_turn.usage
			cli_session_id:    acp_turn.session_id
			provider_attempts: 1
		}
	}
	if spec.protocol == 'app-server' {
		codex_turn := run_codex_cli_turn_cancellable(spec.exec, cwd, permission_mode,
			cli_model, safe_resume_id, prompt, timeout_ms, on_text_delta, decide, config.cli_cancel)!
		if codex_turn.outcome != 'completed' {
			return error('installed CLI ${spec.name} turn ${codex_turn.outcome}')
		}
		return CompletionOutput{
			provider:          config.provider
			model:             if codex_turn.model.len > 0 {
				codex_turn.model
			} else {
				config.model
			}
			content:           codex_turn.text
			cli_session_id:    codex_turn.thread_id
			provider_attempts: 1
		}
	}
	turn := run_claude_cli_turn_observed(spec.exec, cwd, permission_mode, safe_resume_id,
		prompt, timeout_ms, on_text_delta, decide, config.turn_facts, config.cli_cancel)!
	if turn.outcome != 'completed' {
		return error('installed CLI ${spec.name} turn ${turn.outcome}')
	}
	return CompletionOutput{
		provider:          config.provider
		model:             if turn.model.len > 0 { turn.model } else { config.model }
		content:           turn.text
		usage:             turn.usage
		cli_session_id:    turn.session_id
		provider_attempts: 1
	}
}
