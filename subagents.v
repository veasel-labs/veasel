module main

import uuid
import os
import os.filelock
import strconv
import json2

const max_subagent_depth = 2
const max_active_subagent_runs_per_parent = 4
const max_subagent_runs_per_parent = 32
const max_subagent_result_bytes = 64 * 1024
const max_subagent_error_bytes = 4 * 1024

pub struct SubagentRun {
pub:
	id                    string
	request_id            string
	parent_session_id     string
	parent_operation_id   string
	child_session_id      string
	child_operation_id    string
	agent_id              string
	requested_title       string
	task                  string
	target_provider       string
	target_model          string
	provider              string
	model                 string
	depth                 int
	status                string
	result                string
	error                 string
	cancel_requested      bool
	outcome_claimed       bool
	workspace_ready       bool
	workspace_started     bool
	workspace_base_commit string
	input_tokens          i64
	output_tokens         i64
	usage_reported        bool
	cache_read_tokens     i64
	cache_creation_tokens i64
	cache_reported        bool
	reasoning_tokens      i64
	reasoning_reported    bool
}

// create_subagent_run atomically creates a clean child session and its durable
// ownership record. It accepts only built-in profile IDs; it does not authorize
// callers or expose model tools.
fn (mut store Store) create_subagent_run(parent_session_id string, parent_operation_id string,
	request_id string, agent_id string, depth int, title string, directory string) !SubagentRun {
	return store.create_subagent_run_with_task(parent_session_id, parent_operation_id, request_id,
		agent_id, depth, title, directory, '')
}

fn (mut store Store) create_subagent_run_with_task(parent_session_id string, parent_operation_id string,
	request_id string, agent_id string, depth int, title string, directory string, task string) !SubagentRun {
	return store.create_subagent_run_with_cancel_reason(parent_session_id, parent_operation_id,
		request_id, agent_id, depth, title, directory, '', '', '', '', '', task)
}

fn (mut store Store) create_subagent_run_with_cancel_reason(parent_session_id string, parent_operation_id string,
	request_id string, agent_id string, depth int, title string, directory string,
	initial_cancel_reason string, target_provider string, target_model string, provider string,
	model string, task string) !SubagentRun {
	if request_id.len == 0 || request_id.len > 128 || request_id.contains('\0') || agent_id.len == 0
		|| agent_id.len > 128 || agent_id.contains('\0') || parent_operation_id.len == 0
		|| parent_operation_id.len > 128 {
		return error('child agent request or agent ID is invalid')
	}
	_ = builtin_subagent_profile(agent_id) or { return err }
	if depth < 1 || depth > max_subagent_depth {
		return error('child agent nesting limit exceeded')
	}
	if directory.len == 0 || directory.len > 4096 || title.len == 0 || title.len > 512 {
		return error('child agent session metadata is invalid')
	}
	if task.len > 8192 {
		return error('child agent task exceeds its limit')
	}
	if (target_provider.len == 0) != (target_model.len == 0)
		|| (provider.len == 0) != (model.len == 0) {
		return error('child agent model target is invalid')
	}
	if store.path == ':memory:' {
		return error('child agent workspaces require a persistent store')
	}
	store.mu.lock()
	mut store_locked := true
	defer {
		if store_locked {
			store.mu.unlock()
		}
	}
	store.db.exec('BEGIN IMMEDIATE') or { return error('unable to reserve child agent capacity') }
	prior := store.db.exec_param_many('SELECT id, agent_id, requested_title, requested_directory, depth, workspace_ready, target_provider, target_model, task FROM subagent_runs WHERE parent_session_id = ? AND parent_operation_id = ? AND request_id = ?', [
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
			|| row.val(4).int() != depth || row.val(6) != target_provider || row.val(7) != target_model
			|| row.val(8) != task {
			store.db.rollback() or {}
			return error('child agent request key was reused with different parameters')
		}
		store.db.commit() or {
			store.db.rollback() or {}
			return error('unable to commit child agent retry lookup')
		}
		run := store.get_subagent_run_unlocked(row.val(0))!
		store.mu.unlock()
		store_locked = false
		terminal_and_delivered := run.outcome_claimed
			&& run.status in ['completed', 'failed', 'cancelled', 'uncertain']
		if !run.workspace_ready && !terminal_and_delivered {
			return error('child agent workspace preparation is already in progress or was interrupted')
		}
		return run
	}
	operation := store.db.exec_param_many('SELECT status FROM session_operations WHERE id = ? AND session_id = ?',
		[parent_operation_id, parent_session_id]) or {
		store.db.rollback() or {}
		return error('unable to verify parent operation')
	}
	if operation.len != 1 || operation[0].val(0) !in ['running', 'completed', 'failed', 'uncertain'] {
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
	preparation_lock_path := subagent_preparation_lock_path(os.dir(os.real_path(store.path)),
		run_id) or {
		store.db.rollback() or {}
		return err
	}
	mut preparation_lock := new_subagent_preparation_lock(preparation_lock_path) or {
		store.db.rollback() or {}
		return err
	}
	preparation_lock.acquire() or {
		store.db.rollback() or {}
		return error('unable to lock child workspace preparation')
	}
	defer {
		preparation_lock.release()
	}
	child_session_id := uuid.new_v4().str()
	child_operation_id := uuid.new_v4().str()
	child_directory := os.join_path(os.dir(os.real_path(store.path)), 'subagent-worktrees', run_id)
	_ = store.db.exec_param_many('INSERT INTO sessions (id, title, directory) VALUES (?, ?, ?)', [
		child_session_id,
		title,
		child_directory,
	]) or {
		store.db.rollback() or {}
		return error('unable to create child agent session')
	}
	_ = store.db.exec_param2('INSERT INTO events (type, session_id) VALUES (?, ?)', 'session.created',
		child_session_id) or {
		store.db.rollback() or {}
		return error('unable to record child agent session')
	}
	_ = store.db.exec_param_many("INSERT INTO subagent_runs (id, request_id, parent_session_id, parent_operation_id, child_session_id, child_operation_id, agent_id, requested_title, requested_directory, depth, status, target_provider, target_model, provider, model, task, workspace_ready, workspace_started) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'queued', ?, ?, ?, ?, ?, 0, 0)",
		[run_id, request_id, parent_session_id, parent_operation_id, child_session_id,
			child_operation_id, agent_id, title, directory, depth.str(), target_provider, target_model,
			provider, model, task]) or {
		store.db.rollback() or {}
		return error('unable to persist child agent ownership')
	}
	if initial_cancel_reason.len > 0 {
		_ = store.db.exec_param_many("UPDATE subagent_runs SET status = 'cancelled', error = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND status = 'queued'",
			[initial_cancel_reason.limit(max_subagent_error_bytes), run_id]) or {
			store.db.rollback() or {}
			return error('unable to record pre-start child agent cancellation')
		}
		if store.db.get_affected_rows_count() != 1 {
			store.db.rollback() or {}
			return error('unable to record pre-start child agent cancellation')
		}
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit child agent run')
	}
	if initial_cancel_reason.len > 0 {
		return store.get_subagent_run_unlocked(run_id)
	}
	// Keep in-process cleanup from mistaking a live workspace preparation for
	// an interrupted one after the parent turn is cancelled or completed.
	store.active_subagent_preparations[run_id] = true
	store.mu.unlock()
	store_locked = false
	workspace := create_subagent_workspace(directory, os.dir(os.real_path(store.path)), run_id) or {
		remove_subagent_workspace(directory, os.dir(os.real_path(store.path)), run_id, true) or {}
		store.mu.lock()
		store_locked = true
		store.active_subagent_preparations.delete(run_id)
		_ = store.db.exec_param_many("UPDATE subagent_runs SET status = 'failed', error = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND status = 'queued'",
			[err.msg().limit(max_subagent_error_bytes), run_id]) or { return err }
		store.mu.unlock()
		store_locked = false
		return error('unable to prepare child agent workspace: ${err.msg()}')
	}
	store.mu.lock()
	store_locked = true
	store.active_subagent_preparations.delete(run_id)
	_ = store.db.exec_param_many("UPDATE subagent_runs SET workspace_ready = 1, workspace_base_commit = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND status = 'queued' AND EXISTS (SELECT 1 FROM session_operations WHERE id = ? AND session_id = ? AND status IN ('running', 'completed', 'failed', 'uncertain'))",
		[workspace.base_commit, run_id, parent_operation_id, parent_session_id]) or {
		store.mu.unlock()
		store_locked = false
		remove_subagent_workspace(directory, os.dir(os.real_path(store.path)), run_id, true) or {}
		return error('unable to activate child agent workspace')
	}
	if store.db.get_affected_rows_count() != 1 {
		store.mu.unlock()
		store_locked = false
		remove_subagent_workspace(directory, os.dir(os.real_path(store.path)), run_id, true) or {}
		return error('parent operation ended before child workspace was ready')
	}
	run := store.get_subagent_run_unlocked(run_id) or {
		store.mu.unlock()
		store_locked = false
		remove_subagent_workspace(directory, os.dir(os.real_path(store.path)), run_id, true) or {}
		return err
	}
	store.mu.unlock()
	store_locked = false
	return run
}

fn (mut store Store) begin_subagent_run(run_id string) !SubagentRun {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	store.db.begin()!
	run_rows := store.db.exec_param_many("SELECT parent_session_id, parent_operation_id FROM subagent_runs WHERE id = ? AND status = 'queued' AND workspace_ready = 1",
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
	if parent_operation.len != 1 || parent_operation[0].val(0) !in ['running', 'completed', 'failed',
		'uncertain'] {
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
	_ = store.db.exec_param_many("UPDATE subagent_runs SET status = 'running', workspace_started = 1, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND status = 'queued'",
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

fn (mut store Store) cancel_queued_subagent_run(run_id string, reason string) !SubagentRun {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	_ = store.db.exec_param_many("UPDATE subagent_runs SET status = 'cancelled', error = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND status = 'queued' AND workspace_ready = 1 AND workspace_started = 0",
		[reason.limit(max_subagent_error_bytes), run_id])!
	if store.db.get_affected_rows_count() == 1 {
		return store.get_subagent_run_unlocked(run_id)
	}
	run := store.get_subagent_run_unlocked(run_id)!
	if run.status == 'cancelled' && !run.workspace_started {
		return run
	}
	return error('child agent run is no longer queued')
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
	_ = store.db.exec_param_many("UPDATE subagent_runs SET status = CASE WHEN cancel_requested = 1 THEN 'cancelled' ELSE ? END, result = CASE WHEN cancel_requested = 1 THEN '' ELSE ? END, error = CASE WHEN cancel_requested = 1 THEN error ELSE ? END, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND status = 'running'",
		[status, result, run_error, run_id])!
	if store.db.get_affected_rows_count() == 0 {
		return error('child agent run is not running')
	}
	return store.get_subagent_run_unlocked(run_id)
}

fn (mut store Store) fail_queued_subagent_run(run_id string, run_error string) !SubagentRun {
	if run_error.trim_space().len == 0 || run_error.len > max_subagent_error_bytes {
		return error('child agent start failure is invalid')
	}
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	_ = store.db.exec_param_many("UPDATE subagent_runs SET status = 'failed', error = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND status = 'queued'",
		[run_error, run_id])!
	if store.db.get_affected_rows_count() != 1 {
		return error('child agent run is no longer queued')
	}
	return store.get_subagent_run_unlocked(run_id)
}

// claim_subagent_outcome records delivery in the parent event stream in the
// same transaction as the durable claim. Retries return the same terminal run,
// so a restarted parent can fetch its result again by run ID.
fn (mut store Store) claim_subagent_outcome(run_id string) !SubagentRun {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	store.db.begin()!
	run := store.get_subagent_run_unlocked(run_id) or {
		store.db.rollback() or {}
		return err
	}
	if run.status !in ['completed', 'failed', 'cancelled', 'uncertain'] {
		store.db.rollback() or {}
		return error('child agent outcome is not available')
	}
	if run.outcome_claimed {
		store.db.commit() or {
			store.db.rollback() or {}
			return error('unable to commit child outcome retry')
		}
		return run
	}
	_ = store.db.exec_param_many('UPDATE subagent_runs SET outcome_claimed = 1, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND outcome_claimed = 0',
		[run_id]) or {
		store.db.rollback() or {}
		return error('unable to persist child outcome claim')
	}
	if store.db.get_affected_rows_count() != 1 {
		store.db.rollback() or {}
		return error('child agent outcome claim raced with another caller')
	}
	_ = store.db.exec_param_many('INSERT INTO events (type, session_id, data) VALUES (?, ?, ?)', [
		'subagent.outcome_delivered',
		run.parent_session_id,
		json2.encode[EventData](EventData{
			operation_id:       run.parent_operation_id
			subagent_run_id:    run.id
			subagent_status:    run.status
			subagent_untrusted: true
		}),
	]) or {
		store.db.rollback() or {}
		return error('unable to persist parent child outcome event')
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit parent child outcome delivery')
	}
	return store.get_subagent_run_unlocked(run_id)
}

fn (mut store Store) get_subagent_run_unlocked(run_id string) !SubagentRun {
	rows := store.db.exec_param_many('SELECT r.id, r.request_id, r.parent_session_id, r.parent_operation_id, r.child_session_id, r.child_operation_id, r.agent_id, r.depth, r.status, r.result, r.error, r.outcome_claimed, r.cancel_requested, r.workspace_ready, r.workspace_started, r.workspace_base_commit, r.target_provider, r.target_model, r.provider, r.model, r.requested_title, r.task, COALESCE(o.input_tokens, 0), COALESCE(o.output_tokens, 0), COALESCE(o.usage_reported, 0), COALESCE(o.cache_read_tokens, 0), COALESCE(o.cache_creation_tokens, 0), COALESCE(o.cache_reported, 0), COALESCE(o.reasoning_tokens, 0), COALESCE(o.reasoning_reported, 0) FROM subagent_runs r LEFT JOIN session_operations o ON o.id = r.child_operation_id AND o.session_id = r.child_session_id WHERE r.id = ?',
		[run_id])!
	if rows.len != 1 {
		return error('child agent run not found')
	}
	row := rows[0]
	return SubagentRun{
		id:                    row.val(0)
		request_id:            row.val(1)
		parent_session_id:     row.val(2)
		parent_operation_id:   row.val(3)
		child_session_id:      row.val(4)
		child_operation_id:    row.val(5)
		agent_id:              row.val(6)
		depth:                 row.val(7).int()
		status:                row.val(8)
		result:                row.val(9)
		error:                 row.val(10)
		outcome_claimed:       row.val(11).int() == 1
		cancel_requested:      row.val(12).int() == 1
		workspace_ready:       row.val(13).int() == 1
		workspace_started:     row.val(14).int() == 1
		workspace_base_commit: row.val(15)
		target_provider:       row.val(16)
		target_model:          row.val(17)
		provider:              row.val(18)
		model:                 row.val(19)
		requested_title:       row.val(20)
		task:                  row.val(21)
		input_tokens:          row.val(22).i64()
		output_tokens:         row.val(23).i64()
		usage_reported:        row.val(24).int() == 1
		cache_read_tokens:     row.val(25).i64()
		cache_creation_tokens: row.val(26).i64()
		cache_reported:        row.val(27).int() == 1
		reasoning_tokens:      row.val(28).i64()
		reasoning_reported:    row.val(29).int() == 1
	}
}

// ensure_subagent_parent_operation attaches a manually delegated child to the
// latest durable conversation operation. Empty sessions receive an explicit
// synthetic user-delegation group, with no model identity or transcript turn.
fn (mut store Store) ensure_subagent_parent_operation(session_id string) !string {
	store.mu.lock()
	defer { store.mu.unlock() }
	store.db.begin()!
	sessions := store.db.exec_param_many('SELECT id FROM sessions WHERE id = ?', [session_id]) or {
		store.db.rollback() or {}
		return error('unable to verify parent conversation')
	}
	if sessions.len != 1 {
		store.db.rollback() or {}
		return error('parent conversation not found')
	}
	latest := store.db.exec_param_many('SELECT id, status FROM session_operations WHERE session_id = ? ORDER BY rowid DESC LIMIT 1',
		[session_id]) or {
		store.db.rollback() or {}
		return error('unable to find parent conversation operation')
	}
	if latest.len == 1 {
		store.db.commit() or {
			store.db.rollback() or {}
			return error('unable to commit parent operation lookup')
		}
		return latest[0].val(0)
	}
	operation_id := uuid.new_v4().str()
	_ = store.db.exec_param_many("INSERT INTO session_operations (id, session_id, status, provider, model, error, request_json, input_tokens, output_tokens, usage_reported, created_at, updated_at) VALUES (?, ?, 'completed', '', '', '', '', 0, 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
		[operation_id, session_id]) or {
		store.db.rollback() or {}
		return error('unable to create manual delegation group')
	}
	_ = store.db.exec_param_many('INSERT INTO events (type, session_id, data) VALUES (?, ?, ?)', [
		'subagent.user_delegation',
		session_id,
		json2.encode[EventData](EventData{
			operation_id: operation_id
			status:       'completed'
		}),
	]) or {
		store.db.rollback() or {}
		return error('unable to record manual delegation group')
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit manual delegation group')
	}
	return operation_id
}

fn (mut store Store) get_subagent_run(run_id string) !SubagentRun {
	store.mu.lock()
	defer { store.mu.unlock() }
	return store.get_subagent_run_unlocked(run_id)
}

fn (mut store Store) list_subagent_runs(parent_session_id string) ![]SubagentRun {
	store.mu.lock()
	defer { store.mu.unlock() }
	rows := store.db.exec_param_many('SELECT id FROM subagent_runs WHERE parent_session_id = ? ORDER BY created_at, rowid',
		[parent_session_id])!
	mut runs := []SubagentRun{cap: rows.len}
	for row in rows {
		runs << store.get_subagent_run_unlocked(row.val(0))!
	}
	return runs
}

fn (mut store Store) request_subagent_run_cancellation(run_id string, reason string) !SubagentRun {
	if reason.trim_space().len == 0 || reason.len > max_subagent_error_bytes {
		return error('child cancellation reason is invalid')
	}
	store.mu.lock()
	defer { store.mu.unlock() }
	store.db.begin()!
	run := store.get_subagent_run_unlocked(run_id) or {
		store.db.rollback() or {}
		return err
	}
	if run.status == 'queued' {
		_ = store.db.exec_param_many("UPDATE subagent_runs SET status = 'cancelled', cancel_requested = 1, error = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND status = 'queued'",
			[reason, run_id]) or {
			store.db.rollback() or {}
			return error('unable to cancel queued child run')
		}
	} else if run.status == 'running' && !run.cancel_requested {
		_ = store.db.exec_param_many("UPDATE subagent_runs SET cancel_requested = 1, error = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND status = 'running' AND cancel_requested = 0",
			[reason, run_id]) or {
			store.db.rollback() or {}
			return error('unable to request child run cancellation')
		}
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit child run cancellation')
	}
	return store.get_subagent_run_unlocked(run_id)
}

// request_subagent_cancellations_unlocked is called inside the owning
// operation's transaction. Queued children stop before execution; running
// children receive a durable cancellation signal for their worker to observe.
fn (mut store Store) request_subagent_cancellations_unlocked(parent_session_id string,
	parent_operation_id string, reason string) ! {
	_ = store.db.exec_param_many("UPDATE subagent_runs SET status = 'cancelled', error = ?, updated_at = CURRENT_TIMESTAMP WHERE parent_session_id = ? AND parent_operation_id = ? AND status = 'queued'",
		[reason, parent_session_id, parent_operation_id])!
	_ = store.db.exec_param_many("UPDATE subagent_runs SET cancel_requested = 1, error = ?, updated_at = CURRENT_TIMESTAMP WHERE parent_session_id = ? AND parent_operation_id = ? AND status = 'running' AND cancel_requested = 0",
		[reason, parent_session_id, parent_operation_id])!
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

// Reconcile workspaces from runs that crashed while preparing, before queued
// parent operations can resume and request more children.
fn (mut store Store) cleanup_unstarted_subagent_workspaces() {
	store.mu.lock()
	rows := store.db.exec("SELECT id, requested_directory, child_session_id FROM subagent_runs WHERE workspace_started = 0 AND status IN ('cancelled', 'failed')") or {
		store.mu.unlock()
		eprintln('veasel: unable to list interrupted child workspaces (${err.msg()})')
		return
	}
	mut run_ids := []string{cap: rows.len}
	mut directories := []string{cap: rows.len}
	mut child_session_ids := []string{cap: rows.len}
	for row in rows {
		if store.active_subagent_preparations[row.val(0)] {
			continue
		}
		run_ids << row.val(0)
		directories << row.val(1)
		child_session_ids << row.val(2)
	}
	store.mu.unlock()
	data_directory := os.dir(os.real_path(store.path))
	for i, run_id in run_ids {
		lock_path := subagent_preparation_lock_path(data_directory, run_id) or {
			eprintln('veasel: unable to lock interrupted child workspace ${run_id} (${err.msg()})')
			continue
		}
		mut preparation_lock := new_subagent_preparation_lock(lock_path) or {
			eprintln('veasel: unable to open interrupted child workspace lock ${run_id} (${err.msg()})')
			continue
		}
		if !preparation_lock.try_acquire() {
			continue
		}
		path := os.join_path(data_directory, 'subagent-worktrees', run_id)
		if os.exists(path) {
			remove_subagent_workspace(directories[i], data_directory, run_id, true) or {
				eprintln('veasel: unable to remove interrupted child workspace ${run_id} (${err.msg()})')
				preparation_lock.release()
				continue
			}
		}
		store.mu.lock()
		store.db.exec_param_many('UPDATE sessions SET directory = ? WHERE id = ? AND directory = ?', [
			directories[i],
			child_session_ids[i],
			path,
		]) or {
			store.mu.unlock()
			eprintln('veasel: unable to restore interrupted child session directory ${run_id} (${err.msg()})')
			preparation_lock.release()
			continue
		}
		store.mu.unlock()
		preparation_lock.release()
	}
}

// Delivered child results, usage, and transcripts are durable in SQLite, so
// their immutable worktrees no longer need to consume the shared Git limit.
// Restore the child session to the original project directory after removal.
fn (mut store Store) cleanup_delivered_subagent_workspaces() {
	store.mu.lock()
	rows := store.db.exec("SELECT id FROM subagent_runs WHERE workspace_started = 1 AND workspace_ready = 1 AND outcome_claimed = 1 AND status IN ('completed', 'failed', 'cancelled', 'uncertain')") or {
		store.mu.unlock()
		eprintln('veasel: unable to list delivered child workspaces (${err.msg()})')
		return
	}
	mut run_ids := []string{cap: rows.len}
	for row in rows {
		run_ids << row.val(0)
	}
	store.mu.unlock()
	for run_id in run_ids {
		store.cleanup_delivered_subagent_workspace(run_id)
	}
}

fn (mut store Store) cleanup_delivered_subagent_workspace(run_id string) {
	store.mu.lock()
	rows := store.db.exec_param_many("SELECT requested_directory, child_session_id, workspace_base_commit FROM subagent_runs WHERE id = ? AND workspace_started = 1 AND workspace_ready = 1 AND outcome_claimed = 1 AND status IN ('completed', 'failed', 'cancelled', 'uncertain')",
		[run_id]) or {
		store.mu.unlock()
		eprintln('veasel: unable to inspect delivered child workspace ${run_id} (${err.msg()})')
		return
	}
	if rows.len != 1 {
		store.mu.unlock()
		return
	}
	directory := rows[0].val(0)
	child_session_id := rows[0].val(1)
	base_commit := rows[0].val(2)
	store.mu.unlock()
	data_directory := os.dir(os.real_path(store.path))
	lock_path := subagent_preparation_lock_path(data_directory, run_id) or {
		eprintln('veasel: unable to lock delivered child workspace ${run_id} (${err.msg()})')
		return
	}
	mut preparation_lock := new_subagent_preparation_lock(lock_path) or {
		eprintln('veasel: unable to open delivered child workspace lock ${run_id} (${err.msg()})')
		return
	}
	if !preparation_lock.try_acquire() {
		return
	}
	defer {
		preparation_lock.release()
	}
	path := os.join_path(data_directory, 'subagent-worktrees', run_id)
	if os.exists(path) {
		if base_commit.len == 0 || !subagent_workspace_is_unchanged(directory, path, run_id,
			base_commit) {
			eprintln('veasel: retaining delivered child workspace ${run_id} because it changed after preparation')
			return
		}
		remove_subagent_workspace(directory, data_directory, run_id, false) or {
			eprintln('veasel: unable to remove delivered child workspace ${run_id} (${err.msg()})')
			return
		}
		checkout := workspace_git_main_checkout(directory) or {
			eprintln('veasel: unable to locate source checkout for delivered child workspace ${run_id}')
			return
		}
		_ = run_workspace_git_command(checkout, ['branch', '-D', 'veasel/subagents/${run_id}']) or {
			eprintln('veasel: unable to remove delivered child workspace branch ${run_id} (${err.msg()})')
			return
		}
	}
	store.mu.lock()
	store.db.begin() or {
		store.mu.unlock()
		eprintln('veasel: unable to record delivered child workspace cleanup ${run_id} (${err.msg()})')
		return
	}
	_ = store.db.exec_param_many('UPDATE sessions SET directory = ? WHERE id = ? AND directory = ?', [
		directory,
		child_session_id,
		path,
	]) or {
		store.db.rollback() or {}
		store.mu.unlock()
		eprintln('veasel: unable to restore delivered child session directory ${run_id} (${err.msg()})')
		return
	}
	_ = store.db.exec_param_many('UPDATE subagent_runs SET workspace_ready = 0, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND workspace_ready = 1 AND outcome_claimed = 1',
		[run_id]) or {
		store.db.rollback() or {}
		store.mu.unlock()
		eprintln('veasel: unable to record delivered child workspace cleanup ${run_id} (${err.msg()})')
		return
	}
	store.db.commit() or {
		store.db.rollback() or {}
		store.mu.unlock()
		eprintln('veasel: unable to commit delivered child workspace cleanup ${run_id} (${err.msg()})')
		return
	}
	store.mu.unlock()
}

// A delivered workspace can be removed only if its tracked snapshot, copied
// untracked files, and ignored-file set still match the generated baseline.
// Any inspection error is treated as a change and preserves the user's files.
fn subagent_workspace_is_unchanged(source string, path string, run_id string,
	base_commit string) bool {
	if !valid_git_object_id(base_commit) || !os.is_dir(path) {
		return false
	}
	branch := 'veasel/subagents/${run_id}'
	worktree := find_workspace_git_worktree(source, path) or { return false }
	if worktree.is_main || worktree.branch != branch {
		return false
	}
	head := run_workspace_git_command(path, ['rev-parse', '--verify', 'HEAD']) or { return false }
	if head.trim_space() != base_commit {
		return false
	}
	tracked_changes := run_workspace_git_command_output(path,
		['status', '--porcelain=v1', '--untracked-files=no'], 1024 * 1024) or { return false }
	if tracked_changes.len > 0 {
		return false
	}
	index_flags := run_workspace_git_command_output(path, ['ls-files', '-v', '-z'],
		max_subagent_untracked_list_bytes) or { return false }
	for entry in index_flags.split('\0') {
		if entry.len > 0 && ((entry[0] >= `a` && entry[0] <= `z`) || entry[0] == `S`) {
			return false
		}
	}
	ignored := run_workspace_git_command_output(path,
		['ls-files', '--others', '--ignored', '--exclude-standard', '-z'], max_subagent_untracked_list_bytes) or {
		return false
	}
	if ignored.len > 0 {
		return false
	}
	baseline_files := subagent_untracked_files(source) or { return false }
	child_files := subagent_untracked_files(path) or { return false }
	if baseline_files.len != child_files.len {
		return false
	}
	for i, baseline in baseline_files {
		child_file := child_files[i]
		if baseline.path != child_file.path || baseline.sha256 != child_file.sha256
			|| baseline.byte_count != child_file.byte_count || baseline.mode != child_file.mode {
			return false
		}
	}
	return true
}

fn subagent_preparation_lock_path(data_directory string, run_id string) !string {
	if !valid_subagent_run_id(run_id) {
		return error('child agent run ID is invalid')
	}
	lock_directory := os.join_path(data_directory, 'subagent-preparations')
	ensure_directory(lock_directory)!
	if os.is_link(lock_directory) {
		return error('child workspace preparation lock directory cannot be a symlink')
	}
	// Keep a bounded set of lock files permanently. os.filelock.new removes its
	// sidecar on release, which can split waiters across old and newly created
	// inodes. Sharding retains concurrency without that unlink race or one file
	// per child run.
	shard := subagent_preparation_lock_shard(run_id)
	lock_path := os.join_path(lock_directory, '${shard}.lock')
	if os.is_link(lock_path) {
		return error('child workspace preparation lock cannot be a symlink')
	}
	return lock_path
}

fn subagent_preparation_lock_shard(run_id string) int {
	// UUID text is hexadecimal. Use its first byte to spread runs over 256
	// persistent lock inodes; collisions only serialize unrelated preparations.
	return int(strconv.parse_int(run_id[0..2], 16, 0) or { 0 })
}

struct SubagentPreparationLock {
	path string
mut:
	fd           int = -1
	windows_lock filelock.FileLock
}

fn prepare_subagent_preparation_lock_file(path string) ! {
	// Create the inode once with private permissions. Platform lock backends lock
	// it in place so release never unlinks an inode that another process opened.
	mut lock_file := os.open_file(path, 'a', 0o600)!
	lock_file.close()
	if os.is_link(path) {
		return error('child workspace preparation lock cannot be a symlink')
	}
}
