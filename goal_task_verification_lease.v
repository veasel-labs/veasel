module main

import db.sqlite
import json2
import time
import uuid

const goal_task_verification_hard_deadline_seconds = 300

// Verification leases are intentionally separate from worker leases. A
// verifier must never be able to reuse a worker's fence or extend the
// attempt's effective deadline.
struct GoalTaskVerificationLease {
pub:
	verification_deadline string
	lease_expires_at      string
	generation            int
	fencing_token         string
}

fn migrate_goal_task_verification_leases(mut db sqlite.DB) ! {
	db.begin()!
	defer { db.rollback() or {} }
	db.exec('CREATE TABLE IF NOT EXISTS goal_task_verification_leases (
		goal_id TEXT NOT NULL,
		task_id TEXT NOT NULL,
		attempt INTEGER NOT NULL CHECK (attempt > 0),
		fencing_token TEXT NOT NULL,
		generation INTEGER NOT NULL CHECK (generation > 0),
		verification_deadline TEXT NOT NULL,
		lease_expires_at TEXT NOT NULL,
		PRIMARY KEY (goal_id, task_id, attempt),
		FOREIGN KEY (goal_id, task_id, attempt) REFERENCES goal_task_attempts(goal_id, task_id, attempt) ON DELETE CASCADE
	)')!
	db.exec('CREATE INDEX IF NOT EXISTS idx_goal_task_verification_leases_expiry ON goal_task_verification_leases(lease_expires_at)')!
	db.exec('INSERT OR IGNORE INTO schema_migrations (version) VALUES (42)')!
	db.commit()!
}

fn (mut store Store) claim_goal_task_verification_lease(goal_id string, task_id string,
	attempt int, lease_seconds int) !GoalTaskVerificationLease {
	if attempt <= 0 || lease_seconds <= 0 {
		return error('goal task verification lease requires attempt and duration')
	}
	store.mu.lock()
	defer { store.mu.unlock() }
	store.db.exec('BEGIN IMMEDIATE')!
	defer { store.db.rollback() or {} }
	rows := store.db.exec_param_many('SELECT a.status, a.effective_deadline, v.fencing_token, v.generation, v.verification_deadline, v.lease_expires_at, s.status FROM goal_task_attempts a JOIN goal_task_states s ON s.goal_id = a.goal_id AND s.task_id = a.task_id LEFT JOIN goal_task_verification_leases v ON v.goal_id = a.goal_id AND v.task_id = a.task_id AND v.attempt = a.attempt WHERE a.goal_id = ? AND a.task_id = ? AND a.attempt = ?', [
		goal_id,
		task_id,
		attempt.str(),
	])!
	if rows.len != 1 || rows[0].val(0) != 'verifying' {
		return error('goal task attempt is not verifying')
	}
	if rows[0].val(6) != 'verifying' {
		return error('goal task is no longer awaiting verification')
	}
	bindings := store.db.exec_param_many("SELECT status FROM goal_task_verifier_bindings WHERE goal_id = ? AND task_id = ? AND attempt = ? AND status = 'consumed'", [
		goal_id,
		task_id,
		attempt.str(),
	])!
	if bindings.len > 0 {
		return error('goal task verification already has a consumed reviewer binding')
	}
	effective := time.parse_rfc3339(rows[0].val(1)) or { return error('goal task effective deadline is invalid') }
	now := time.now()
	if now >= effective {
		return error('goal task attempt deadline has expired')
	}
	if rows[0].val(2) != '' {
		lease_expiry := time.parse_rfc3339(rows[0].val(5)) or { return error('goal task verification lease expiry is invalid') }
		if now < lease_expiry {
			return error('goal task verification lease is already held')
		}
		binding_rows := store.db.exec_param_many("SELECT status, COALESCE(reviewer_run_id, '') FROM goal_task_verifier_bindings WHERE goal_id = ? AND task_id = ? AND attempt = ?", [
			goal_id,
			task_id,
			attempt.str(),
		])!
		if binding_rows.len == 1
			&& (binding_rows[0].val(0) == 'bound' || binding_rows[0].val(1).len > 0) {
			return error('expired bound reviewer run cannot be reclaimed safely; expire the task as uncertain')
		}
		existing_hard := time.parse_rfc3339(rows[0].val(4)) or { return error('goal task verification deadline is invalid') }
		if now >= existing_hard {
			return error('goal task verification deadline has expired')
		}
	}
	mut hard_deadline := now.add(time.second * goal_task_verification_hard_deadline_seconds)
	if rows[0].val(2) != '' {
		hard_deadline = time.parse_rfc3339(rows[0].val(4)) or { return error('goal task verification deadline is invalid') }
	} else if hard_deadline > effective {
		hard_deadline = effective
	}
	mut expires := now.add(time.Duration(lease_seconds) * time.second)
	if expires > hard_deadline {
		expires = hard_deadline
	}
	mut generation := rows[0].val(3).int() + 1
	if generation <= 0 { generation = 1 }
	token := uuid.new_v4().str()
	store.db.exec_param_many('INSERT OR REPLACE INTO goal_task_verification_leases (goal_id, task_id, attempt, fencing_token, generation, verification_deadline, lease_expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)', [
		goal_id,
		task_id,
		attempt.str(),
		token,
		generation.str(),
		hard_deadline.format_rfc3339(),
		expires.format_rfc3339(),
	])!
	if rows[0].val(2) != '' {
		store.db.exec_param_many("UPDATE goal_task_verifier_bindings SET fencing_token = ?, lease_generation = ?, updated_at = CURRENT_TIMESTAMP WHERE goal_id = ? AND task_id = ? AND attempt = ? AND status IN ('reserved', 'bound')", [
			token,
			generation.str(),
			goal_id,
			task_id,
			attempt.str(),
		])!
	}
	store.db.commit()!
	return GoalTaskVerificationLease{ verification_deadline: hard_deadline.format_rfc3339(), lease_expires_at: expires.format_rfc3339(), generation: generation, fencing_token: token }
}

fn (mut store Store) renew_goal_task_verification_lease(goal_id string, task_id string, attempt int,
	fencing_token string, generation int, lease_seconds int) !GoalTaskVerificationLease {
	if fencing_token.len == 0 || generation <= 0 || lease_seconds <= 0 {
		return error('goal task verification lease renewal requires token, generation and duration')
	}
	store.mu.lock()
	defer { store.mu.unlock() }
	store.db.exec('BEGIN IMMEDIATE')!
	defer { store.db.rollback() or {} }
	rows := store.db.exec_param_many('SELECT a.status, a.effective_deadline, v.verification_deadline, v.lease_expires_at FROM goal_task_attempts a JOIN goal_task_verification_leases v ON v.goal_id = a.goal_id AND v.task_id = a.task_id AND v.attempt = a.attempt WHERE a.goal_id = ? AND a.task_id = ? AND a.attempt = ? AND v.fencing_token = ? AND v.generation = ?', [
		goal_id,
		task_id,
		attempt.str(),
		fencing_token,
		generation.str(),
	])!
	if rows.len != 1 || rows[0].val(0) != 'verifying' {
		return error('goal task verification lease is stale or not verifying')
	}
	now := time.now()
	hard := time.parse_rfc3339(rows[0].val(2)) or { return error('goal task verification deadline is invalid') }
	lease := time.parse_rfc3339(rows[0].val(3)) or { return error('goal task verification lease expiry is invalid') }
	if now >= lease || now >= hard { return error('goal task verification lease has expired') }
	mut expires := now.add(time.Duration(lease_seconds) * time.second)
	if expires > hard { expires = hard }
	new_generation := generation + 1
	new_token := uuid.new_v4().str()
	store.db.exec_param_many('UPDATE goal_task_verification_leases SET fencing_token = ?, generation = ?, lease_expires_at = ? WHERE goal_id = ? AND task_id = ? AND attempt = ? AND fencing_token = ? AND generation = ?', [
		new_token,
		new_generation.str(),
		expires.format_rfc3339(),
		goal_id,
		task_id,
		attempt.str(),
		fencing_token,
		generation.str(),
	])!
	if store.db.get_affected_rows_count() != 1 {
		return error('goal task verification lease changed while renewing')
	}
	binding_rows := store.db.exec_param_many('SELECT status, fencing_token, lease_generation FROM goal_task_verifier_bindings WHERE goal_id = ? AND task_id = ? AND attempt = ?', [
		goal_id,
		task_id,
		attempt.str(),
	])!
	if binding_rows.len == 1 {
		if binding_rows[0].val(0) == 'consumed' {
			return error('goal task verification already has a consumed reviewer binding')
		}
		if binding_rows[0].val(0) !in ['reserved', 'bound']
			|| binding_rows[0].val(1) != fencing_token
			|| binding_rows[0].val(2).int() != generation {
			return error('goal task verifier binding fence is stale')
		}
		store.db.exec_param_many("UPDATE goal_task_verifier_bindings SET fencing_token = ?, lease_generation = ?, updated_at = CURRENT_TIMESTAMP WHERE goal_id = ? AND task_id = ? AND attempt = ? AND status IN ('reserved', 'bound') AND fencing_token = ? AND lease_generation = ?", [
			new_token,
			new_generation.str(),
			goal_id,
			task_id,
			attempt.str(),
			fencing_token,
			generation.str(),
		])!
		if store.db.get_affected_rows_count() != 1 {
			return error('goal task verifier binding changed while renewing')
		}
	}
	store.db.commit()!
	return GoalTaskVerificationLease{ verification_deadline: hard.format_rfc3339(), lease_expires_at: expires.format_rfc3339(), generation: new_generation, fencing_token: new_token }
}

fn (mut store Store) validate_goal_task_verification_lease(goal_id string, task_id string, attempt int,
	fencing_token string, generation int) ! {
	if fencing_token.len == 0 || generation <= 0 {
		return error('goal task verification lease fence is required')
	}
	store.mu.lock()
	defer { store.mu.unlock() }
	rows := store.db.exec_param_many('SELECT a.status, v.verification_deadline, v.lease_expires_at FROM goal_task_attempts a JOIN goal_task_verification_leases v ON v.goal_id = a.goal_id AND v.task_id = a.task_id AND v.attempt = a.attempt WHERE a.goal_id = ? AND a.task_id = ? AND a.attempt = ? AND v.fencing_token = ? AND v.generation = ?', [
		goal_id,
		task_id,
		attempt.str(),
		fencing_token,
		generation.str(),
	])!
	if rows.len != 1 || rows[0].val(0) != 'verifying' {
		return error('goal task verification lease is stale or not verifying')
	}
	now := time.now()
	hard := time.parse_rfc3339(rows[0].val(1)) or { return error('goal task verification deadline is invalid') }
	expires := time.parse_rfc3339(rows[0].val(2)) or { return error('goal task verification lease expiry is invalid') }
	if now >= hard || now >= expires { return error('goal task verification lease has expired') }
}

fn (mut store Store) expire_goal_task_verification_lease(goal_id string, task_id string, attempt int,
	fencing_token string, generation int) !bool {
	if fencing_token.len == 0 || generation <= 0 {
		return error('goal task verification lease fence is required')
	}
	store.mu.lock()
	defer { store.mu.unlock() }
	store.db.exec('BEGIN IMMEDIATE')!
	defer { store.db.rollback() or {} }
	rows := store.db.exec_param_many('SELECT a.status, v.lease_expires_at, v.verification_deadline, a.session_id, a.session_operation_id FROM goal_task_attempts a JOIN goal_task_verification_leases v ON v.goal_id = a.goal_id AND v.task_id = a.task_id AND v.attempt = a.attempt WHERE a.goal_id = ? AND a.task_id = ? AND a.attempt = ? AND v.fencing_token = ? AND v.generation = ?', [
		goal_id,
		task_id,
		attempt.str(),
		fencing_token,
		generation.str(),
	])!
	if rows.len != 1 || rows[0].val(0) != 'verifying' {
		return error('goal task verification lease is stale or not verifying')
	}
	now := time.now()
	lease_expiry := time.parse_rfc3339(rows[0].val(1)) or { return error('goal task verification lease expiry is invalid') }
	hard := time.parse_rfc3339(rows[0].val(2)) or { return error('goal task verification deadline is invalid') }
	if now < lease_expiry && now < hard {
		return error('goal task verification lease has not expired')
	}
	receipts := store.db.exec_param_many("SELECT r.verdict FROM goal_task_verification_receipts r JOIN goal_task_verifier_bindings b ON b.id = r.binding_id WHERE r.goal_id = ? AND r.task_id = ? AND r.attempt = ? AND b.status = 'consumed'", [
		goal_id,
		task_id,
		attempt.str(),
	])!
	if receipts.len == 1 && receipts[0].val(0) == 'pass' {
		store.db.exec_param_many('DELETE FROM goal_task_verification_leases WHERE goal_id = ? AND task_id = ? AND attempt = ? AND fencing_token = ? AND generation = ?', [
			goal_id,
			task_id,
			attempt.str(),
			fencing_token,
			generation.str(),
		])!
		if store.db.get_affected_rows_count() != 1 {
			return error('goal task verification lease changed while preserving its pass receipt')
		}
		store.db.commit()!
		return true
	}
	store.db.exec_param_many('DELETE FROM goal_task_verification_leases WHERE goal_id = ? AND task_id = ? AND attempt = ? AND fencing_token = ? AND generation = ?', [
		goal_id,
		task_id,
		attempt.str(),
		fencing_token,
		generation.str(),
	])!
	if store.db.get_affected_rows_count() != 1 {
		return error('goal task verification lease is stale')
	}
	store.db.exec_param_many("UPDATE goal_task_attempts SET status = 'uncertain', ended_at = CURRENT_TIMESTAMP WHERE goal_id = ? AND task_id = ? AND attempt = ? AND status = 'verifying'", [
		goal_id,
		task_id,
		attempt.str(),
	])!
	if store.db.get_affected_rows_count() != 1 {
		return error('goal task attempt changed while expiring verification lease')
	}
	store.db.exec_param_many("UPDATE goal_task_states SET status = 'uncertain', updated_at = CURRENT_TIMESTAMP WHERE goal_id = ? AND task_id = ? AND status = 'verifying'", [
		goal_id,
		task_id,
	])!
	store.db.exec_param_many("UPDATE goal_task_attempt_workspaces SET status = 'uncertain', updated_at = CURRENT_TIMESTAMP WHERE goal_id = ? AND task_id = ? AND attempt = ? AND status IN ('preparing', 'ready')", [
		goal_id,
		task_id,
		attempt.str(),
	])!
	// The canonical session operation is already terminal-completed when an
	// attempt enters verifying; retain that fact and append the uncertainty
	// event for consumers observing verification expiry.
	if rows[0].val(3) != '' && rows[0].val(4) != '' {
		store.db.exec_param_many('INSERT INTO events (type, session_id, data) VALUES (?, ?, ?)', [
			'goal.task_attempt_completed',
			rows[0].val(3),
			json2.encode[GoalTaskEventData](GoalTaskEventData{
				goal_id:      goal_id
				task_id:      task_id
				attempt:      attempt
				operation_id: rows[0].val(4)
				status:       'uncertain'
				outcome:      'uncertain'
				error:        'The verification lease expired before a receipt was recorded.'
			}),
		])!
	}
	store.db.commit()!
	return true
}
