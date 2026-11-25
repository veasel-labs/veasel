module main

import db.sqlite
import json2
import os

// Lifecycle values stay typed in the V state machine. Projections encode their
// string wire values explicitly for the versioned HTTP API.
enum GoalTaskStatus {
	pending
	running
	succeeded
	failed
	uncertain
}

enum GoalTaskAttemptStatus {
	running
	succeeded
	failed
	uncertain
}

enum GoalTaskResult {
	succeeded
	failed
	uncertain
}

fn goal_task_attempt_status_from_db(value string) !GoalTaskAttemptStatus {
	return match value {
		'running' { .running }
		'succeeded' { .succeeded }
		'failed' { .failed }
		'uncertain' { .uncertain }
		else { error('unknown persisted goal task attempt status') }
	}
}

fn goal_task_status_from_db(value string) !GoalTaskStatus {
	return match value {
		'pending' { .pending }
		'running' { .running }
		'succeeded' { .succeeded }
		'failed' { .failed }
		'uncertain' { .uncertain }
		else { error('unknown persisted goal task status') }
	}
}

pub struct GoalTaskAttemptProjection {
pub:
	attempt    int
	status     string
	started_at string
	ended_at   string
}

pub struct GoalTaskProjectionState {
pub:
	status        string
	attempt_count int
	attempts      []GoalTaskAttemptProjection
}

struct GoalTaskOwnerStatus {
	alive    bool
	identity string
}

fn migrate_goal_task_state(mut db sqlite.DB) ! {
	db.begin()!
	defer { db.rollback() or {} }
	db.exec("CREATE TABLE IF NOT EXISTS goal_task_states (
		goal_id TEXT NOT NULL,
		task_id TEXT NOT NULL,
		status TEXT NOT NULL CHECK (status IN ('pending', 'running', 'succeeded', 'failed', 'uncertain')),
		attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
		owner_pid INTEGER NOT NULL DEFAULT 0,
		owner_start_id TEXT NOT NULL DEFAULT '',
		updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
		PRIMARY KEY (goal_id, task_id),
		FOREIGN KEY (goal_id) REFERENCES goal_admissions(id) ON DELETE CASCADE
	)")!
	db.exec("CREATE TABLE IF NOT EXISTS goal_task_attempts (
		goal_id TEXT NOT NULL,
		task_id TEXT NOT NULL,
		attempt INTEGER NOT NULL CHECK (attempt > 0),
		status TEXT NOT NULL CHECK (status IN ('running', 'succeeded', 'failed', 'uncertain')),
		owner_pid INTEGER NOT NULL DEFAULT 0,
		owner_start_id TEXT NOT NULL DEFAULT '',
		started_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
		ended_at TEXT NOT NULL DEFAULT '',
		PRIMARY KEY (goal_id, task_id, attempt),
		FOREIGN KEY (goal_id, task_id) REFERENCES goal_task_states(goal_id, task_id) ON DELETE CASCADE
	)")!
	add_column_if_missing(&db, 'goal_task_states', 'owner_pid', 'INTEGER NOT NULL DEFAULT 0')!
	add_column_if_missing(&db, 'goal_task_states', 'owner_start_id', "TEXT NOT NULL DEFAULT ''")!
	add_column_if_missing(&db, 'goal_task_attempts', 'owner_pid', 'INTEGER NOT NULL DEFAULT 0')!
	add_column_if_missing(&db, 'goal_task_attempts', 'owner_start_id', "TEXT NOT NULL DEFAULT ''")!
	db.exec('CREATE INDEX IF NOT EXISTS idx_goal_task_attempts_status ON goal_task_attempts(status)')!
	db.exec('INSERT OR IGNORE INTO schema_migrations (version) VALUES (36)')!
	db.commit()!
}

// State is seeded for old admissions on open and for each new admission. A
// claim remains running only when its owner is verifiably alive with the same
// process-start identity. Dead, reused, legacy, or unverifiable ownership is
// uncertain and never replayed. Opening another Store preserves verified live
// claims in the current process.
fn initialize_and_recover_goal_task_state(mut db sqlite.DB) ! {
	admissions := db.exec('SELECT manifest FROM goal_admissions')!
	db.begin()!
	defer { db.rollback() or {} }
	for row in admissions {
		goal := json2.decode[GoalAdmission](row.val(0))!
		seed_goal_task_state(mut db, goal)!
	}
	interrupted_attempts := db.exec("SELECT goal_id, task_id, attempt, owner_pid, owner_start_id FROM goal_task_attempts WHERE status = 'running'")!
	for row in interrupted_attempts {
		owner := goal_task_owner_status(row.val(3).int())
		if row.val(4) == '' || !owner.alive || owner.identity == '' || owner.identity != row.val(4) {
			_ = db.exec_param_many("UPDATE goal_task_attempts SET status = 'uncertain', ended_at = CURRENT_TIMESTAMP WHERE goal_id = ? AND task_id = ? AND attempt = ? AND status = 'running'", [
				row.val(0),
				row.val(1),
				row.val(2),
			])!
		}
	}
	interrupted_tasks := db.exec("SELECT goal_id, task_id, owner_pid, owner_start_id FROM goal_task_states WHERE status = 'running'")!
	for row in interrupted_tasks {
		owner := goal_task_owner_status(row.val(2).int())
		if row.val(3) == '' || !owner.alive || owner.identity == '' || owner.identity != row.val(3) {
			_ = db.exec_param_many("UPDATE goal_task_states SET status = 'uncertain', updated_at = CURRENT_TIMESTAMP, owner_pid = 0 WHERE goal_id = ? AND task_id = ? AND status = 'running'", [
				row.val(0),
				row.val(1),
			])!
			_ = db.exec_param_many("UPDATE goal_task_states SET owner_start_id = '' WHERE goal_id = ? AND task_id = ? AND status = 'uncertain'", [
				row.val(0),
				row.val(1),
			])!
		}
	}
	db.commit()!
}

fn seed_goal_task_state(mut db sqlite.DB, goal GoalAdmission) ! {
	for task in goal.tasks {
		db.exec_param_many("INSERT OR IGNORE INTO goal_task_states (goal_id, task_id, status) VALUES (?, ?, 'pending')", [
			goal.id,
			task.id,
		])!
	}
}

fn (mut store Store) goal_task_state(goal_id string, task_id string) !GoalTaskProjectionState {
	store.mu.lock()
	defer { store.mu.unlock() }
	store.db.begin()!
	defer { store.db.rollback() or {} }
	rows := store.db.exec_param_many('SELECT status, attempt_count FROM goal_task_states WHERE goal_id = ? AND task_id = ?', [
		goal_id,
		task_id,
	])!
	if rows.len == 0 {
		return error('goal task state not found')
	}
	state := rows[0]
	attempt_rows := store.db.exec_param_many('SELECT attempt, status, started_at, ended_at FROM goal_task_attempts WHERE goal_id = ? AND task_id = ? ORDER BY attempt', [
		goal_id,
		task_id,
	])!
	store.db.commit()!
	mut attempts := []GoalTaskAttemptProjection{}
	for row in attempt_rows {
		attempts << GoalTaskAttemptProjection{
			attempt: row.val(0).int()
			status: goal_task_attempt_status_from_db(row.val(1))!.str()
			started_at: row.val(2)
			ended_at: row.val(3)
		}
	}
	return GoalTaskProjectionState{
		status: goal_task_status_from_db(state.val(0))!.str()
		attempt_count: state.val(1).int()
		attempts: attempts
	}
}

fn (mut store Store) goal_task_states_for_goal(goal_id string) !map[string]GoalTaskProjectionState {
	store.mu.lock()
	defer { store.mu.unlock() }
	store.db.begin()!
	defer { store.db.rollback() or {} }
	rows := store.db.exec_param_many('SELECT task_id, status, attempt_count FROM goal_task_states WHERE goal_id = ?', [
		goal_id,
	])!
	mut states := map[string]GoalTaskProjectionState{}
	for row in rows {
		attempt_rows := store.db.exec_param_many('SELECT attempt, status, started_at, ended_at FROM goal_task_attempts WHERE goal_id = ? AND task_id = ? ORDER BY attempt', [
			goal_id,
			row.val(0),
		])!
		mut attempts := []GoalTaskAttemptProjection{}
		for attempt_row in attempt_rows {
			attempts << GoalTaskAttemptProjection{
				attempt: attempt_row.val(0).int()
				status: goal_task_attempt_status_from_db(attempt_row.val(1))!.str()
				started_at: attempt_row.val(2)
				ended_at: attempt_row.val(3)
			}
		}
		states[row.val(0)] = GoalTaskProjectionState{
			status: goal_task_status_from_db(row.val(1))!.str()
			attempt_count: row.val(2).int()
			attempts: attempts
		}
	}
	store.db.commit()!
	return states
}

// claim_goal_task atomically claims only a pending task whose dependencies have
// succeeded and whose goal-wide attempt budget has not been exhausted. It is a
// state transition only; it never starts a worker or performs task effects.
fn (mut store Store) claim_goal_task(goal_id string, task_id string) !GoalTaskProjectionState {
	store.mu.lock()
	defer { store.mu.unlock() }
	goal_rows := store.db.exec_param('SELECT manifest FROM goal_admissions WHERE id = ?', goal_id)!
	if goal_rows.len == 0 {
		return error('goal not found')
	}
	goal := json2.decode[GoalAdmission](goal_rows[0].val(0))!
	mut exists := false
	mut dependencies := []string{}
	for task in goal.tasks {
		if task.id == task_id {
			exists = true
			dependencies = task.depends_on.clone()
			break
		}
	}
	if !exists {
		return error('goal task not found')
	}
	store.db.exec('BEGIN IMMEDIATE')!
	defer { store.db.rollback() or {} }
	for dependency in dependencies {
		dependency_rows := store.db.exec_param_many('SELECT status FROM goal_task_states WHERE goal_id = ? AND task_id = ?', [
			goal_id,
			dependency,
		])!
		if dependency_rows.len != 1 || goal_task_status_from_db(dependency_rows[0].val(0))! != .succeeded {
			return error('goal task dependencies are not complete')
		}
	}
	used_attempts := store.db.exec_param('SELECT COUNT(*) FROM goal_task_attempts WHERE goal_id = ?', goal_id)!
	if used_attempts.len != 1 || used_attempts[0].val(0).int() >= goal.budget.max_attempts {
		return error('goal attempt budget is exhausted')
	}
	pid := os.getpid().str()
	owner_status := goal_task_owner_status(os.getpid())
	if !owner_status.alive || owner_status.identity == '' {
		return error('unable to verify goal task owner process identity')
	}
	owner_start_id := owner_status.identity
	_ = store.db.exec_param_many('UPDATE goal_task_states SET status = ?, attempt_count = attempt_count + 1, updated_at = CURRENT_TIMESTAMP, owner_pid = ?, owner_start_id = ? WHERE goal_id = ? AND task_id = ? AND status = ?', [
		GoalTaskStatus.running.str(),
		pid,
		owner_start_id,
		goal_id,
		task_id,
		GoalTaskStatus.pending.str(),
	])!
	if store.db.get_affected_rows_count() != 1 {
		return error('goal task is not claimable')
	}
	attempt_rows := store.db.exec_param_many('SELECT attempt_count FROM goal_task_states WHERE goal_id = ? AND task_id = ?', [
		goal_id,
		task_id,
	])!
	attempt := attempt_rows[0].val(0)
	_ = store.db.exec_param_many("INSERT INTO goal_task_attempts (goal_id, task_id, attempt, status, owner_pid, owner_start_id) VALUES (?, ?, ?, 'running', ?, ?)", [
		goal_id,
		task_id,
		attempt,
		pid,
		owner_start_id,
	])!
	store.db.commit()!
	return store.goal_task_state_unlocked(goal_id, task_id)!
}

// complete_goal_task_attempt records an explicit result. Failed attempts return
// the task to pending while budget remains; uncertain results are never retried.
fn (mut store Store) complete_goal_task_attempt(goal_id string, task_id string, attempt int, result GoalTaskResult) ! {
	store.mu.lock()
	defer { store.mu.unlock() }
	store.db.begin()!
	defer { store.db.rollback() or {} }
	_ = store.db.exec_param_many("UPDATE goal_task_attempts SET status = ?, ended_at = CURRENT_TIMESTAMP WHERE goal_id = ? AND task_id = ? AND attempt = ? AND status = 'running'", [
		result.str(),
		goal_id,
		task_id,
		attempt.str(),
	])!
	if store.db.get_affected_rows_count() != 1 {
		return error('goal task attempt is not running')
	}
	goal_rows := store.db.exec_param('SELECT manifest FROM goal_admissions WHERE id = ?', goal_id)!
	if goal_rows.len == 0 {
		return error('goal not found')
	}
	goal := json2.decode[GoalAdmission](goal_rows[0].val(0))!
	used_attempts := store.db.exec_param('SELECT COUNT(*) FROM goal_task_attempts WHERE goal_id = ?', goal_id)!
	if used_attempts.len != 1 {
		return error('unable to read goal attempt budget')
	}
	status := match result {
		.succeeded { GoalTaskStatus.succeeded }
		.uncertain { GoalTaskStatus.uncertain }
		.failed {
			if used_attempts[0].val(0).int() < goal.budget.max_attempts {
				GoalTaskStatus.pending
			} else {
				GoalTaskStatus.failed
			}
		}
	}
	_ = store.db.exec_param_many("UPDATE goal_task_states SET status = ?, updated_at = CURRENT_TIMESTAMP, owner_pid = 0, owner_start_id = '' WHERE goal_id = ? AND task_id = ? AND status = ?", [
		status.str(),
		goal_id,
		task_id,
		GoalTaskStatus.running.str(),
	])!
	if store.db.get_affected_rows_count() != 1 {
		return error('goal task is not running')
	}
	store.db.commit()!
}

fn (mut store Store) goal_task_state_unlocked(goal_id string, task_id string) !GoalTaskProjectionState {
	store.db.begin()!
	defer { store.db.rollback() or {} }
	rows := store.db.exec_param_many('SELECT status, attempt_count FROM goal_task_states WHERE goal_id = ? AND task_id = ?', [
		goal_id,
		task_id,
	])!
	if rows.len == 0 {
		return error('goal task state not found')
	}
	state := rows[0]
	attempt_rows := store.db.exec_param_many('SELECT attempt, status, started_at, ended_at FROM goal_task_attempts WHERE goal_id = ? AND task_id = ? ORDER BY attempt', [
		goal_id,
		task_id,
	])!
	store.db.commit()!
	mut attempts := []GoalTaskAttemptProjection{}
	for row in attempt_rows {
		attempts << GoalTaskAttemptProjection{
			attempt: row.val(0).int()
			status: goal_task_attempt_status_from_db(row.val(1))!.str()
			started_at: row.val(2)
			ended_at: row.val(3)
		}
	}
	return GoalTaskProjectionState{
		status: goal_task_status_from_db(state.val(0))!.str()
		attempt_count: state.val(1).int()
		attempts: attempts
	}
}
