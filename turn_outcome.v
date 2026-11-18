module main

import os
import sync
import time
import json2

// Durable per-turn outcomes (epic #689, item B).
//
// `session_operations.status` is the lifecycle of the turn (did it reach a
// recorded end). `outcome` is what the turn actually did, derived only from
// facts Veasel recorded while it ran: approval decisions, and edits/commands
// the CLI reported as applied. A turn that applied edits is never reduced to
// a generic failure, and applied work is never presented as verified.

const turn_outcome_values = ['completed', 'completed_with_denials', 'partial', 'failed', 'cancelled',
	'uncertain']

// TurnOutcomeFacts is the recorded evidence behind an outcome.
pub struct TurnOutcomeFacts {
pub mut:
	approvals_approved int
	approvals_denied   int
	approvals_expired  int
	// Edit-type tool calls the CLI reported as applied, e.g. "Edit math.js".
	edits_applied []string
	// Approval-gated commands the CLI reported as run, by executable only
	// (arguments can carry secrets), e.g. "Bash (git)".
	commands_ran  []string
	expired_tools []string
	denied_tools  []string
	// True when the provider protocol lets Veasel see tool results (Claude
	// stream-json). When false, applied changes are unknown, not zero.
	effects_observed bool
	// Veasel does not run or read tests for CLI turns, so verification is
	// always 'not_reported' unless a future adapter reports it.
	verification string = 'not_reported'
}

pub struct TurnOutcome {
pub:
	outcome string
	summary string
	facts   TurnOutcomeFacts
}

struct TurnOutcomeDetail {
pub:
	summary string
	facts   TurnOutcomeFacts
}

fn (facts TurnOutcomeFacts) has_effects() bool {
	return facts.edits_applied.len > 0 || facts.commands_ran.len > 0
}

fn (facts TurnOutcomeFacts) applied_list() string {
	mut items := facts.edits_applied.clone()
	items << facts.commands_ran
	return items.join(', ')
}

fn (facts TurnOutcomeFacts) approvals_clause() string {
	mut parts := []string{}
	if facts.approvals_denied > 0 {
		parts << '${facts.approvals_denied} denied'
	}
	if facts.approvals_expired > 0 {
		parts << '${facts.approvals_expired} expired'
	}
	if parts.len == 0 {
		return ''
	}
	mut tools := facts.denied_tools.clone()
	tools << facts.expired_tools
	return 'Approvals: ${parts.join(', ')} (${tools.join(', ')}).'
}

const unverified_notice = 'These changes are not verified by Veasel; review the diff and run your tests.'

// derive_turn_outcome maps the turn lifecycle plus recorded facts to the
// durable outcome and its public summary. lifecycle is the status the turn
// reached: completed, failed, cancelled or uncertain. public_error is the
// already-sanitized failure text for failed/cancelled/uncertain turns.
fn derive_turn_outcome(lifecycle string, facts TurnOutcomeFacts, public_error string) TurnOutcome {
	denied := facts.approvals_denied + facts.approvals_expired
	approvals := facts.approvals_clause()
	match lifecycle {
		'completed' {
			if denied > 0 {
				summary := if facts.has_effects() {
					'${approvals} Applied: ${facts.applied_list()}. ${unverified_notice}'
				} else if facts.effects_observed {
					'${approvals} No changes were applied.'
				} else {
					'${approvals} Veasel could not observe whether any changes were applied for this provider.'
				}
				return TurnOutcome{
					outcome: 'completed_with_denials'
					summary: summary
					facts:   facts
				}
			}
			if facts.has_effects() {
				return TurnOutcome{
					outcome: 'completed'
					summary: 'Applied: ${facts.applied_list()}. ${unverified_notice}'
					facts:   facts
				}
			}
			return TurnOutcome{
				outcome: 'completed'
				facts:   facts
			}
		}
		'cancelled' {
			summary := if facts.has_effects() {
				'${public_error} Already applied before the stop: ${facts.applied_list()}. ${unverified_notice}'
			} else {
				public_error
			}
			return TurnOutcome{
				outcome: 'cancelled'
				summary: summary
				facts:   facts
			}
		}
		'uncertain' {
			summary := if facts.has_effects() {
				'${public_error} Applied before the interruption: ${facts.applied_list()}. ${unverified_notice}'
			} else {
				public_error
			}
			return TurnOutcome{
				outcome: 'uncertain'
				summary: summary
				facts:   facts
			}
		}
		else {
			if facts.has_effects() {
				mut parts := [
					'The turn stopped before it finished (${public_error.trim_right('.')}).',
					'Already applied: ${facts.applied_list()}.',
				]
				if approvals.len > 0 {
					parts << approvals
				}
				parts << unverified_notice
				return TurnOutcome{
					outcome: 'partial'
					summary: parts.join(' ')
					facts:   facts
				}
			}
			if !facts.effects_observed && facts.approvals_approved > 0 {
				return TurnOutcome{
					outcome: 'uncertain'
					summary: '${public_error} ${facts.approvals_approved} approved action(s) ran, and Veasel could not observe whether they took effect for this provider.'
					facts:   facts
				}
			}
			return TurnOutcome{
				outcome: 'failed'
				summary: public_error
				facts:   facts
			}
		}
	}
}

fn turn_outcome_detail_json(outcome TurnOutcome) string {
	if outcome.outcome.len == 0 {
		return ''
	}
	return json2.encode(TurnOutcomeDetail{
		summary: outcome.summary
		facts:   outcome.facts
	})
}

fn turn_outcome_detail_from_json(raw string) TurnOutcomeDetail {
	if raw.len == 0 {
		return TurnOutcomeDetail{}
	}
	return json2.decode[TurnOutcomeDetail](raw) or { TurnOutcomeDetail{} }
}

// TurnFacts collects the facts of the turn that currently runs in one
// session. Sessions run one turn at a time, so it is keyed by session id.
@[heap]
pub struct TurnFacts {
mut:
	mu         &sync.Mutex = sync.new_mutex()
	facts      TurnOutcomeFacts
	tools      map[string]PendingToolCall
	gated_tool map[string]bool
}

struct PendingToolCall {
	name    string
	summary string
}

fn new_turn_facts(effects_observed bool) &TurnFacts {
	return &TurnFacts{
		facts: TurnOutcomeFacts{
			effects_observed: effects_observed
		}
	}
}

fn (mut facts TurnFacts) snapshot() TurnOutcomeFacts {
	facts.mu.lock()
	defer {
		facts.mu.unlock()
	}
	return TurnOutcomeFacts{
		...facts.facts
		edits_applied: facts.facts.edits_applied.clone()
		commands_ran:  facts.facts.commands_ran.clone()
		expired_tools: facts.facts.expired_tools.clone()
		denied_tools:  facts.facts.denied_tools.clone()
	}
}

fn (mut facts TurnFacts) set_effects_observed(observed bool) {
	facts.mu.lock()
	facts.facts.effects_observed = observed
	facts.mu.unlock()
}

// note_approval records one human (or policy) decision.
fn (mut facts TurnFacts) note_approval(tool_name string, decision string) {
	facts.mu.lock()
	defer {
		facts.mu.unlock()
	}
	match decision {
		'approved' { facts.facts.approvals_approved++ }
		'expired' {
			facts.facts.approvals_expired++
			facts.facts.expired_tools << tool_name
		}
		else {
			facts.facts.approvals_denied++
			facts.facts.denied_tools << tool_name
		}
	}
}

// note_tool_use remembers a tool call so its result can be classified.
fn (mut facts TurnFacts) note_tool_use(tool_id string, tool_name string, input_json string) {
	if tool_id.len == 0 {
		return
	}
	facts.mu.lock()
	facts.tools[tool_id] = PendingToolCall{
		name:    tool_name
		summary: tool_call_summary(tool_name, input_json)
	}
	facts.mu.unlock()
}

// note_gated marks a tool call that required an approval.
fn (mut facts TurnFacts) note_gated(tool_id string) {
	if tool_id.len == 0 {
		return
	}
	facts.mu.lock()
	facts.gated_tool[tool_id] = true
	facts.mu.unlock()
}

// note_tool_result records what the CLI reported for a tool call. Only a
// successful edit, or a successful approval-gated command, counts as an
// applied side effect; read-only tool calls never do.
fn (mut facts TurnFacts) note_tool_result(tool_id string, is_error bool) {
	facts.mu.lock()
	defer {
		facts.mu.unlock()
	}
	call := facts.tools[tool_id] or { return }
	if is_error {
		return
	}
	if call.name in ['Edit', 'Write', 'MultiEdit', 'NotebookEdit'] {
		facts.facts.edits_applied << call.summary
	} else if call.name == 'Bash' && facts.gated_tool[tool_id] {
		facts.facts.commands_ran << call.summary
	}
}

// tool_call_summary names the tool and its target without arguments that
// could carry secrets: a path for edits, the executable for commands.
fn tool_call_summary(tool_name string, input_json string) string {
	input := json2.decode[map[string]json2.Any](input_json) or { return tool_name }
	if tool_name == 'Bash' {
		command := if value := input['command'] {
			if value is string { value.trim_space() } else { '' }
		} else {
			''
		}
		executable := command.split(' ')[0]
		return if executable.len > 0 { 'Bash (${executable})' } else { 'Bash' }
	}
	for key in ['file_path', 'notebook_path', 'path'] {
		if value := input[key] {
			if value is string && value.len > 0 {
				return '${tool_name} ${path_base_name(value)}'
			}
		}
	}
	return tool_name
}

fn path_base_name(path string) string {
	parts := path.replace('\\', '/').split('/')
	return if parts.len > 0 { parts[parts.len - 1] } else { path }
}

@[heap]
struct TurnFactsRegistry {
mut:
	mu         &sync.Mutex = sync.new_mutex()
	by_session map[string]&TurnFacts
}

fn new_turn_facts_registry() &TurnFactsRegistry {
	return &TurnFactsRegistry{}
}

fn (mut registry TurnFactsRegistry) begin(session_id string) &TurnFacts {
	registry.mu.lock()
	defer {
		registry.mu.unlock()
	}
	facts := new_turn_facts(false)
	registry.by_session[session_id] = facts
	return facts
}

// get_or_begin returns the facts of the turn running in the session, starting
// them when the caller is the first to need them (direct provider calls).
fn (mut registry TurnFactsRegistry) get_or_begin(session_id string) &TurnFacts {
	registry.mu.lock()
	defer {
		registry.mu.unlock()
	}
	if existing := registry.by_session[session_id] {
		return existing
	}
	// Child-session turns never call finish; bound the map instead of
	// tracking their lifecycle.
	if registry.by_session.len >= 512 {
		registry.by_session.clear()
	}
	facts := new_turn_facts(false)
	registry.by_session[session_id] = facts
	return facts
}

fn (mut registry TurnFactsRegistry) snapshot(session_id string) TurnOutcomeFacts {
	registry.mu.lock()
	mut facts := registry.by_session[session_id] or {
		registry.mu.unlock()
		return TurnOutcomeFacts{}
	}
	registry.mu.unlock()
	return facts.snapshot()
}

fn (mut registry TurnFactsRegistry) finish(session_id string) {
	registry.mu.lock()
	registry.by_session.delete(session_id)
	registry.mu.unlock()
}

// Default time a person has to answer one CLI approval. It is deliberately
// shorter than the CLI turn timeout (120s): when it lapses the request is
// denied in-band and the CLI can wrap up, instead of the whole turn timing
// out underneath an unanswered approval.
const default_cli_approval_timeout_seconds = 60

fn cli_approval_timeout() time.Duration {
	raw := os.getenv_opt('VEASEL_CLI_APPROVAL_TIMEOUT_SECONDS') or { '' }
	seconds := raw.int()
	if seconds < 1 || seconds > 3600 {
		return default_cli_approval_timeout_seconds * time.second
	}
	return seconds * time.second
}

// cli_approval_decider builds the per-turn approval callback for an
// installed-CLI session turn. Without VEASEL_CLI_INTERACTIVE_APPROVALS every
// request is denied immediately; with it each request becomes a durable
// pending approval that a client approves or denies. Nothing is auto-approved:
// expiry and a failed read both mean deny, and every decision is recorded in
// facts for the turn outcome.
fn (app &App) cli_approval_decider(session_id string, request_deadline time.Time, facts &TurnFacts, cancel CliCancelFn) CliApprovalDecisionFn {
	if os.getenv_opt('VEASEL_CLI_INTERACTIVE_APPROVALS') or { '' } != '1' {
		return fn [facts] (request_id string, tool_name string, input_json string) bool {
			mut observed := unsafe { facts }
			observed.note_approval(tool_name, 'denied')
			return false
		}
	}
	timeout_deadline := time.now().add(cli_approval_timeout())
	wait_deadline := if timeout_deadline < request_deadline {
		timeout_deadline
	} else {
		request_deadline
	}
	return fn [app, session_id, wait_deadline, facts, cancel] (request_id string, tool_name string, input_json string) bool {
		mut observed := unsafe { facts }
		mut store := app.store
		approval := store.create_cli_tool_approval(session_id, request_id, tool_name, input_json) or {
			observed.note_approval(tool_name, 'denied')
			return false
		}
		for time.now() < wait_deadline {
			// A cancelled or expired turn must not keep a person waiting on a
			// request nothing will act on: expire it and deny in-band.
			if _ := cli_cancel_reason(cancel) {
				store.expire_cli_tool_approval(approval.id) or {}
				observed.note_approval(tool_name, 'expired')
				return false
			}
			current := store.get_cli_tool_approval(approval.id) or {
				observed.note_approval(tool_name, 'denied')
				return false
			}
			match current.status {
				'approved' {
					observed.note_approval(tool_name, 'approved')
					return true
				}
				'denied', 'expired' {
					observed.note_approval(tool_name, 'denied')
					return false
				}
				else {}
			}
			time.sleep(200 * time.millisecond)
		}
		store.expire_cli_tool_approval(approval.id) or {}
		observed.note_approval(tool_name, 'expired')
		return false
	}
}
