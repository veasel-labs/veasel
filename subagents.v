module main

import uuid

const max_subagent_depth = 2
const max_active_subagent_runs_per_parent = 4
const max_subagent_runs_per_parent = 32
const max_subagent_result_bytes = 64 * 1024
const max_subagent_error_bytes = 4 * 1024

pub struct SubagentRun {
pub:
	id                  string
	request_id          string
	parent_session_id   string
	parent_operation_id string
	child_session_id    string
	agent_id            string
	depth               int
	status              string
	result              string
	error               string
	cancel_requested    bool
	outcome_claimed     bool
}

// create_subagent_run atomically creates a clean child session and its durable
// ownership record. agent_id must come from a trusted, caller-side registry;
// this storage primitive does not authorize agents or expose model tools.
fn (mut store Store) create_subagent_run(parent_session_id string, parent_operation_id string,
	request_id string, agent_id string, depth int, title string, directory string) !SubagentRun {
	if request_id.len == 0 || request_id.len > 128 || request_id.contains('\0') || agent_id.len == 0
		|| agent_id.len > 128 || agent_id.contains('\0') || parent_operation_id.len == 0
		|| parent_operation_id.len > 128 {
		return error('child agent request or agent ID is invalid')
	}
	if depth < 1 || depth > max_subagent_depth {
		return error('child agent nesting limit exceeded')
	}
	if directory.len == 0 || directory.len > 4096 || title.len == 0 || title.len > 512 {
		return error('child agent session metadata is invalid')
	}
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	store.db.exec('BEGIN IMMEDIATE') or { return error('unable to reserve child agent capacity') }
	prior := store.db.exec_param_many('SELECT id, agent_id, requested_title, requested_directory, depth FROM subagent_runs WHERE parent_session_id = ? AND parent_operation_id = ? AND request_id = ?', [
		parent_session_id,
		parent_operation_id,
		request_id,
	]) or {
		store.db.rollback() or {}
		return error('unable to look up child agent retry')
	}
	if prior.len == 1 {
		row := prior[0]
		if row.val(1) != agent_id || row.val(2) != title || row.val(3) != directory
			|| row.val(4).int() != depth {
			store.db.rollback() or {}
			return error('child agent request key was reused with different parameters')
		}
		store.db.commit() or {
			store.db.rollback() or {}
			return error('unable to commit child agent retry lookup')
		}
		return store.get_subagent_run_unlocked(row.val(0))
	}
	operation := store.db.exec_param_many('SELECT status FROM session_operations WHERE id = ? AND session_id = ?',
		[parent_operation_id, parent_session_id]) or {
		store.db.rollback() or {}
		return error('unable to verify parent operation')
	}
	if operation.len != 1 || operation[0].val(0) != 'running' {
		store.db.rollback() or {}
		return error('parent operation is not running')
	}
	parent_run := store.db.exec_param_many('SELECT depth FROM subagent_runs WHERE child_session_id = ?',
		[parent_session_id]) or {
		store.db.rollback() or {}
		return error('unable to verify parent nesting depth')
	}
	expected_depth := if parent_run.len == 0 { 1 } else { parent_run[0].val(0).int() + 1 }
	if depth != expected_depth {
		store.db.rollback() or {}
		return error('child agent nesting depth is invalid')
	}
	counts := store.db.exec_param_many("SELECT COUNT(*), SUM(CASE WHEN status IN ('queued', 'running') THEN 1 ELSE 0 END) FROM subagent_runs WHERE parent_session_id = ?",
		[parent_session_id]) or {
		store.db.rollback() or {}
		return error('unable to count child agent runs')
	}
	if counts[0].val(0).int() >= max_subagent_runs_per_parent {
		store.db.rollback() or {}
		return error('child agent persistence ceiling reached')
	}
	if counts[0].val(1).int() >= max_active_subagent_runs_per_parent {
		store.db.rollback() or {}
		return error('child agent concurrency limit reached')
	}
	run_id := uuid.new_v4().str()
	child_session_id := uuid.new_v4().str()
	_ = store.db.exec_param_many('INSERT INTO sessions (id, title, directory) VALUES (?, ?, ?)', [
		child_session_id,
		title,
		directory,
	]) or {
		store.db.rollback() or {}
		return error('unable to create child agent session')
	}
	_ = store.db.exec_param2('INSERT INTO events (type, session_id) VALUES (?, ?)', 'session.created',
		child_session_id) or {
		store.db.rollback() or {}
		return error('unable to record child agent session')
	}
	_ = store.db.exec_param_many("INSERT INTO subagent_runs (id, request_id, parent_session_id, parent_operation_id, child_session_id, agent_id, requested_title, requested_directory, depth, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'queued')",
		[run_id, request_id, parent_session_id, parent_operation_id, child_session_id, agent_id,
			title, directory, depth.str()]) or {
		store.db.rollback() or {}
		return error('unable to persist child agent ownership')
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit child agent run')
	}
	return store.get_subagent_run_unlocked(run_id)
}

fn (mut store Store) begin_subagent_run(run_id string) !SubagentRun {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	store.db.begin()!
	run_rows := store.db.exec_param_many("SELECT parent_session_id, parent_operation_id FROM subagent_runs WHERE id = ? AND status = 'queued'",
		[run_id]) or {
		store.db.rollback() or {}
		return error('unable to inspect queued child agent run')
	}
	if run_rows.len != 1 {
		store.db.rollback() or {}
		return error('child agent run is not queued')
	}
	parent_operation := store.db.exec_param_many('SELECT status FROM session_operations WHERE id = ? AND session_id = ?',
		[run_rows[0].val(1), run_rows[0].val(0)]) or {
		store.db.rollback() or {}
		return error('unable to verify parent operation state')
	}
	if parent_operation.len != 1 || parent_operation[0].val(0) != 'running' {
		store.db.rollback() or {}
		return error('parent operation is not running')
	}
	rows := store.db.exec_param_many("SELECT COUNT(*) FROM subagent_runs WHERE parent_session_id = ? AND status = 'running'",
		[run_rows[0].val(0)]) or {
		store.db.rollback() or {}
		return error('unable to count active child agent runs')
	}
	if rows.len != 1 || rows[0].val(0).int() >= max_active_subagent_runs_per_parent {
		store.db.rollback() or {}
		return error('child agent concurrency limit reached')
	}
	_ = store.db.exec_param_many("UPDATE subagent_runs SET status = 'running', updated_at = CURRENT_TIMESTAMP WHERE id = ? AND status = 'queued'",
		[run_id]) or {
		store.db.rollback() or {}
		return error('unable to start child agent run')
	}
	if store.db.get_affected_rows_count() != 1 {
		store.db.rollback() or {}
		return error('child agent run is not queued')
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit child agent start')
	}
	return store.get_subagent_run_unlocked(run_id)
}

fn (mut store Store) finish_subagent_run(run_id string, status string, result string, run_error string) !SubagentRun {
	if status !in ['completed', 'failed', 'cancelled', 'uncertain'] {
		return error('child agent terminal status is invalid')
	}
	if result.len > max_subagent_result_bytes {
		return error('child agent result exceeds size limit')
	}
	if run_error.len > max_subagent_error_bytes {
		return error('child agent error exceeds size limit')
	}
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	_ = store.db.exec_param_many("UPDATE subagent_runs SET status = ?, result = ?, error = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND status = 'running'",
		[status, result, run_error, run_id])!
	if store.db.get_affected_rows_count() == 0 {
		return error('child agent run is not running')
	}
	return store.get_subagent_run_unlocked(run_id)
}

// claim_subagent_outcome provides an at-most-once claim, not end-to-end delivery:
// callers must commit the parent result durably before treating it as delivered.
fn (mut store Store) claim_subagent_outcome(run_id string) !SubagentRun {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	run := store.get_subagent_run_unlocked(run_id)!
	if run.outcome_claimed {
		return error('child agent outcome was already claimed')
	}
	if run.status !in ['completed', 'failed', 'cancelled', 'uncertain'] {
		return error('child agent outcome is not available')
	}
	_ = store.db.exec_param_many('UPDATE subagent_runs SET outcome_claimed = 1, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND outcome_claimed = 0',
		[run_id])!
	if store.db.get_affected_rows_count() != 1 {
		return error('child agent outcome was already claimed')
	}
	return store.get_subagent_run_unlocked(run_id)
}

fn (mut store Store) get_subagent_run_unlocked(run_id string) !SubagentRun {
	rows := store.db.exec_param_many('SELECT id, request_id, parent_session_id, parent_operation_id, child_session_id, agent_id, depth, status, result, error, outcome_claimed, cancel_requested FROM subagent_runs WHERE id = ?',
		[run_id])!
	if rows.len != 1 {
		return error('child agent run not found')
	}
	row := rows[0]
	return SubagentRun{
		id:                  row.val(0)
		request_id:          row.val(1)
		parent_session_id:   row.val(2)
		parent_operation_id: row.val(3)
		child_session_id:    row.val(4)
		agent_id:            row.val(5)
		depth:               row.val(6).int()
		status:              row.val(7)
		result:              row.val(8)
		error:               row.val(9)
		outcome_claimed:     row.val(10).int() == 1
		cancel_requested:    row.val(11).int() == 1
	}
}

// request_subagent_cancellations_unlocked is called inside the owning
// operation's transaction. Queued children stop before execution; running
// children receive a durable cancellation signal for their worker to observe.
fn (mut store Store) request_subagent_cancellations_unlocked(parent_session_id string,
	parent_operation_id string, reason string) ! {
	_ = store.db.exec_param_many("UPDATE subagent_runs SET status = 'cancelled', error = ?, updated_at = CURRENT_TIMESTAMP WHERE parent_session_id = ? AND parent_operation_id = ? AND status = 'queued'",
		[reason, parent_session_id, parent_operation_id])!
	_ = store.db.exec_param_many("UPDATE subagent_runs SET cancel_requested = 1, updated_at = CURRENT_TIMESTAMP WHERE parent_session_id = ? AND parent_operation_id = ? AND status = 'running' AND cancel_requested = 0",
		[parent_session_id, parent_operation_id])!
}

// subagent_cancellation_requested lets a future child worker observe the
// parent's durable cancellation request without holding the store lock while
// it waits for provider or tool work to stop.
fn (mut store Store) subagent_cancellation_requested(run_id string) !bool {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	run := store.get_subagent_run_unlocked(run_id)!
	if run.status != 'running' {
		return error('child agent run is not running')
	}
	return run.cancel_requested
}
