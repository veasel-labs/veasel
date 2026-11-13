module main

import json2
import os
import strconv
import uuid

const default_child_agent_token_budget = i64(262144)
const default_parent_agent_token_budget = i64(1048576)
const max_configured_agent_token_budget = i64(50000000)
const max_provider_attempts_per_call = 1 + provider_transient_retry_delays_ms.len
const agent_token_budget_protocol_overhead_bytes = 4096

// AgentTokenBudgetPolicy is a validated process policy. It is intentionally
// environment-backed in this slice so deployments can set a ceiling without
// creating mutable per-session policy that children could widen.
struct AgentTokenBudgetPolicy {
	child_tokens  i64
	parent_tokens i64
}

struct AgentTokenBudgetReservation {
	id              string
	root_session_id string
	session_id      string
	reserved_tokens i64
	child_limit     i64
	parent_limit    i64
}

pub struct AgentTokenBudgetSummary {
pub:
	root_session_id       string
	per_child_token_limit i64
	parent_token_limit    i64
	reserved_tokens       i64
	accounted_tokens      i64
	actual_tokens         i64
	provider_calls        int
	usage_reported_calls  int
	usage_complete        bool
	reported_cost_usd     ?f64 @[omitempty]
	cost_reported_calls   int
	cost_reported         bool
}

fn agent_token_budget_policy() !AgentTokenBudgetPolicy {
	child_tokens := configured_agent_token_budget('VEASEL_AGENT_CHILD_TOKEN_BUDGET',
		default_child_agent_token_budget)!
	parent_tokens := configured_agent_token_budget('VEASEL_AGENT_PARENT_TOKEN_BUDGET',
		default_parent_agent_token_budget)!
	if child_tokens > parent_tokens {
		return error('VEASEL_AGENT_CHILD_TOKEN_BUDGET cannot exceed VEASEL_AGENT_PARENT_TOKEN_BUDGET')
	}
	return AgentTokenBudgetPolicy{
		child_tokens:  child_tokens
		parent_tokens: parent_tokens
	}
}

fn configured_agent_token_budget(name string, fallback i64) !i64 {
	raw := os.getenv_opt(name) or { return fallback }
	value := strconv.parse_int(raw, 10, 64) or {
		return error('${name} must be an integer from 1 to ${max_configured_agent_token_budget}')
	}
	if value < 1 || value > max_configured_agent_token_budget {
		return error('${name} must be an integer from 1 to ${max_configured_agent_token_budget}')
	}
	return value
}

// provider_call_reservation_tokens uses UTF-8 serialized request bytes as an
// intentionally conservative bound (at most one token per byte), includes
// tool schemas, reserves the adapter's output ceiling, and accounts for every
// bounded transient retry. It is an admission bound, never reported usage.
fn provider_call_reservation_tokens(messages []ChatMessage, tools []AgentToolDefinition,
	config ModelConfig) i64 {
	mut request_bytes := json2.encode[[]ChatMessage](messages).len
	request_bytes += json2.encode[[]AgentToolDefinition](tools).len
	request_bytes += agent_token_budget_protocol_overhead_bytes
	mut output_tokens := config.max_output_tokens
	if output_tokens <= 0 {
		output_tokens = max_model_output_tokens
	}
	per_attempt := i64(request_bytes) + i64(output_tokens)
	return per_attempt * i64(max_provider_attempts_per_call)
}

fn actual_agent_provider_tokens(provider string, usage ProviderUsage) i64 {
	total := usage.input_tokens + usage.output_tokens
	// Anthropic reports cache read/write tokens disjoint from input_tokens;
	// OpenAI and Gemini cache reads are already included in input_tokens.
	if provider == 'anthropic' && usage.cache_reported {
		return total + usage.cache_read_tokens + usage.cache_creation_tokens
	}
	return total
}

fn (mut store Store) reserve_agent_provider_call(session_id string, requested_tokens i64,
	policy AgentTokenBudgetPolicy) !AgentTokenBudgetReservation {
	if session_id.len == 0 || requested_tokens <= 0 {
		return error('agent token budget reservation is invalid')
	}
	reservation_id := uuid.new_v4().str()
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	store.db.exec('BEGIN IMMEDIATE') or {
		return error('unable to begin agent token budget reservation')
	}
	root_rows := store.db.exec_param_many('WITH RECURSIVE ancestry(session_id, parent_session_id, depth) AS (SELECT ?, NULL, 0 UNION ALL SELECT r.parent_session_id, r.parent_session_id, ancestry.depth + 1 FROM subagent_runs r JOIN ancestry ON r.child_session_id = ancestry.session_id WHERE ancestry.depth < 2) SELECT session_id FROM ancestry ORDER BY depth DESC LIMIT 1', [
		session_id,
	]) or {
		store.db.rollback() or {}
		return error('unable to resolve parent agent token budget')
	}
	if root_rows.len != 1 {
		store.db.rollback() or {}
		return error('unable to resolve parent agent token budget')
	}
	root_session_id := root_rows[0].val(0)
	child_rows := store.db.exec_param_many('SELECT COUNT(*) FROM subagent_runs WHERE child_session_id = ?', [
		session_id,
	]) or {
		store.db.rollback() or {}
		return error('unable to inspect child agent token budget')
	}
	is_child := child_rows.len == 1 && child_rows[0].val(0).i64() > 0
	mut child_used := i64(0)
	if is_child {
		used_rows := store.db.exec_param_many("WITH RECURSIVE descendants(session_id, depth) AS (SELECT ?, 0 UNION ALL SELECT r.child_session_id, descendants.depth + 1 FROM subagent_runs r JOIN descendants ON r.parent_session_id = descendants.session_id WHERE descendants.depth < 2) SELECT COALESCE(SUM(b.accounted_tokens), 0) FROM agent_token_budget_reservations b JOIN descendants d ON d.session_id = b.session_id WHERE b.status IN ('reserved', 'settled', 'uncertain')", [
			session_id,
		]) or {
			store.db.rollback() or {}
			return error('unable to inspect child agent token budget')
		}
		child_used = used_rows[0].val(0).i64()
		if child_used + requested_tokens > policy.child_tokens {
			store.db.rollback() or {}
			return error('child agent token budget exhausted: reservation requires ${requested_tokens} tokens, ${policy.child_tokens - child_used} remain')
		}
	}
	parent_rows := store.db.exec_param_many("SELECT COALESCE(SUM(accounted_tokens), 0) FROM agent_token_budget_reservations WHERE root_session_id = ? AND status IN ('reserved', 'settled', 'uncertain')", [
		root_session_id,
	]) or {
		store.db.rollback() or {}
		return error('unable to inspect parent agent token budget')
	}
	parent_used := parent_rows[0].val(0).i64()
	if parent_used + requested_tokens > policy.parent_tokens {
		store.db.rollback() or {}
		return error('parent agent token budget exhausted: reservation requires ${requested_tokens} tokens, ${policy.parent_tokens - parent_used} remain')
	}
	_ = store.db.exec_param_many("INSERT INTO agent_token_budget_reservations (id, root_session_id, session_id, reserved_tokens, accounted_tokens, status) VALUES (?, ?, ?, ?, ?, 'reserved')", [
		reservation_id,
		root_session_id,
		session_id,
		requested_tokens.str(),
		requested_tokens.str(),
	]) or {
		store.db.rollback() or {}
		return error('unable to persist agent token budget reservation')
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit agent token budget reservation')
	}
	return AgentTokenBudgetReservation{
		id:              reservation_id
		root_session_id: root_session_id
		session_id:      session_id
		reserved_tokens: requested_tokens
		child_limit:     policy.child_tokens
		parent_limit:    policy.parent_tokens
	}
}

// settle_agent_provider_call releases unused reservation only when one
// provider attempt returned adapter-reported token usage. Multiple attempts or
// missing usage retain the full bound because failed attempts may be billable.
fn (mut store Store) settle_agent_provider_call(reservation AgentTokenBudgetReservation,
	provider string, usage ProviderUsage, attempts int) ! {
	accounted := if usage.reported && attempts == 1 {
		actual_agent_provider_tokens(provider, usage)
	} else {
		reservation.reserved_tokens
	}
	status := if usage.reported && attempts == 1 { 'settled' } else { 'uncertain' }
	actual_cost := if attempts == 1 { usage.reported_cost_usd or { 0.0 } } else { 0.0 }
	cost_reported := if attempts == 1 && usage.reported_cost_usd != none { 1 } else { 0 }
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	_ = store.db.exec_param_many('UPDATE agent_token_budget_reservations SET accounted_tokens = ?, status = ?, actual_tokens = ?, usage_reported = ?, reported_cost_usd = ?, cost_reported = ? WHERE id = ? AND status = ?', [
		accounted.str(),
		status,
		if usage.reported && attempts == 1 { accounted.str() } else { '0' },
		if usage.reported && attempts == 1 { '1' } else { '0' },
		actual_cost.str(),
		cost_reported.str(),
		reservation.id,
		'reserved',
	]) or { return error('unable to settle agent token budget reservation') }
}

fn (mut store Store) agent_token_budget_summary(session_id string,
	policy AgentTokenBudgetPolicy) !AgentTokenBudgetSummary {
	_ = store.get_session(session_id) or { return error('session not found') }
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	root_rows := store.db.exec_param_many('WITH RECURSIVE ancestry(session_id, depth) AS (SELECT ?, 0 UNION ALL SELECT r.parent_session_id, ancestry.depth + 1 FROM subagent_runs r JOIN ancestry ON r.child_session_id = ancestry.session_id WHERE ancestry.depth < 2) SELECT session_id FROM ancestry ORDER BY depth DESC LIMIT 1', [
		session_id,
	]) or { return error('unable to resolve parent agent token budget') }
	if root_rows.len != 1 {
		return error('unable to resolve parent agent token budget')
	}
	root_session_id := root_rows[0].val(0)
	rows := store.db.exec_param_many("SELECT COALESCE(SUM(CASE WHEN status = 'reserved' THEN reserved_tokens ELSE 0 END), 0), COALESCE(SUM(accounted_tokens), 0), COALESCE(SUM(actual_tokens), 0), COUNT(*), COALESCE(SUM(usage_reported), 0), COALESCE(SUM(CASE WHEN usage_reported = 0 THEN 1 ELSE 0 END), 0), COALESCE(SUM(CASE WHEN cost_reported = 1 THEN reported_cost_usd ELSE 0 END), 0), COALESCE(SUM(cost_reported), 0), COALESCE(SUM(CASE WHEN cost_reported = 0 THEN 1 ELSE 0 END), 0) FROM agent_token_budget_reservations WHERE root_session_id = ? AND status != 'released'", [
		root_session_id,
	]) or { return error('unable to read parent agent token budget') }
	row := rows[0]
	call_count := row.val(3).int()
	usage_missing := row.val(5).int() > 0
	cost_missing := row.val(8).int() > 0
	known_cost_calls := row.val(7).int()
	return AgentTokenBudgetSummary{
		root_session_id:       root_session_id
		per_child_token_limit: policy.child_tokens
		parent_token_limit:    policy.parent_tokens
		reserved_tokens:       row.val(0).i64()
		accounted_tokens:      row.val(1).i64()
		actual_tokens:         row.val(2).i64()
		provider_calls:        call_count
		usage_reported_calls:  row.val(4).int()
		usage_complete:        !usage_missing
		reported_cost_usd:     if call_count > 0 && known_cost_calls == call_count {
			row.val(6).f64()
		} else {
			none
		}
		cost_reported_calls:   known_cost_calls
		cost_reported:         call_count > 0 && !cost_missing
	}
}

fn (mut store Store) abandon_agent_provider_call(reservation AgentTokenBudgetReservation) {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	_ = store.db.exec_param_many("UPDATE agent_token_budget_reservations SET status = 'uncertain' WHERE id = ? AND status = 'reserved'", [
		reservation.id,
	]) or { return }
}

fn (mut store Store) release_agent_provider_call(reservation AgentTokenBudgetReservation) {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	_ = store.db.exec_param_many("UPDATE agent_token_budget_reservations SET status = 'released', accounted_tokens = 0 WHERE id = ? AND status = 'reserved'", [
		reservation.id,
	]) or { return }
}
