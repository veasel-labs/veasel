module main

import db.sqlite
import json2
import os
import time
import uuid

// Lifecycle values stay typed in the V state machine. Projections encode their
// string wire values explicitly for the versioned HTTP API.
enum GoalTaskStatus {
	pending
	running
	verifying
	verified
	succeeded
	failed
	uncertain
}

enum GoalTaskAttemptStatus {
	running
	verifying
	succeeded
	failed
	uncertain
}

enum GoalTaskResult {
	verifying
	succeeded
	failed
	uncertain
}

fn goal_task_attempt_status_from_db(value string) !GoalTaskAttemptStatus {
	return match value {
		'running' { .running }
		'verifying' { .verifying }
		'succeeded' { .succeeded }
		'failed' { .failed }
		'uncertain' { .uncertain }
		else { error('unknown persisted goal task attempt status') }
	}
}

// SQLite cannot widen a CHECK constraint in place. Rebuild only the task state
// table with foreign-key enforcement suspended; child rows remain untouched.
fn migrate_goal_task_verified_state(mut db sqlite.DB) ! {
	db.exec('PRAGMA foreign_keys = OFF')!
	db.exec('PRAGMA legacy_alter_table = ON')!
	db.begin()!
	defer {
		db.rollback() or {}
		db.exec('PRAGMA legacy_alter_table = OFF') or {}
		db.exec('PRAGMA foreign_keys = ON') or {}
	}
	db.exec('ALTER TABLE goal_task_states RENAME TO goal_task_states_v43')!
	db.exec("CREATE TABLE goal_task_states (
		goal_id TEXT NOT NULL,
		task_id TEXT NOT NULL,
		status TEXT NOT NULL CHECK (status IN ('pending', 'running', 'verifying', 'verified', 'succeeded', 'failed', 'uncertain')),
		attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
		owner_pid INTEGER NOT NULL DEFAULT 0,
		owner_start_id TEXT NOT NULL DEFAULT '',
		updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
		PRIMARY KEY (goal_id, task_id),
		FOREIGN KEY (goal_id) REFERENCES goal_admissions(id) ON DELETE CASCADE
	)")!
	db.exec('INSERT INTO goal_task_states SELECT * FROM goal_task_states_v43')!
	db.exec('DROP TABLE goal_task_states_v43')!
	db.exec('INSERT INTO schema_migrations (version) VALUES (44)')!
	db.commit()!
	db.exec('PRAGMA legacy_alter_table = OFF')!
	db.exec('PRAGMA foreign_keys = ON')!
}

fn goal_task_status_from_db(value string) !GoalTaskStatus {
	return match value {
		'pending' { .pending }
		'running' { .running }
		'verifying' { .verifying }
		'verified' { .verified }
		'succeeded' { .succeeded }
		'failed' { .failed }
		'uncertain' { .uncertain }
		else { error('unknown persisted goal task status') }
	}
}

pub struct GoalTaskAttemptProjection {
pub:
	attempt            int
	status             string
	started_at         string
	ended_at           string
	effective_deadline string
	lease_expires_at   string
	lease_generation   int
}

pub struct GoalTaskProjectionState {
pub:
	status        string
	attempt_count int
	attempts      []GoalTaskAttemptProjection
}

struct GoalTaskClaim {
	state                GoalTaskProjectionState
	session_operation_id string
	fencing_token        string
	lease_generation     int
	effective_deadline   string
	lease_expires_at     string
}

struct GoalTaskLease {
pub:
	effective_deadline string
	lease_expires_at   string
	generation         int
	fencing_token      string
}

// GoalTaskLeaseBinding is the exact fence a worker currently owns. The token
// and generation are advanced together on every renewal; callers must retain
// both values and never reuse an older pair for a terminal transition.
struct GoalTaskLeaseBinding {
mut:
	goal_id       string
	task_id       string
	attempt       int
	fencing_token string
	generation    int
}

struct GoalTaskLeaseLookup {
	linked  bool
	binding GoalTaskLeaseBinding
}

const goal_task_initial_lease_seconds = 90

struct GoalTaskEventData {
	goal_id      string
	task_id      string
	attempt      int
	operation_id string
	status       string
	outcome      string
	error        string
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
	add_column_if_missing(&db, 'goal_task_attempts', 'session_id', "TEXT NOT NULL DEFAULT ''")!
	add_column_if_missing(&db, 'goal_task_attempts', 'session_operation_id', "TEXT NOT NULL DEFAULT ''")!
	add_column_if_missing(&db, 'goal_task_attempts', 'fencing_token', "TEXT NOT NULL DEFAULT ''")!
	db.exec('CREATE INDEX IF NOT EXISTS idx_goal_task_attempts_status ON goal_task_attempts(status)')!
	db.exec('INSERT OR IGNORE INTO schema_migrations (version) VALUES (36)')!
	db.exec('INSERT OR IGNORE INTO schema_migrations (version) VALUES (37)')!
	db.commit()!
}

// This migration is deliberately additive. Existing attempts remain terminal
// or recoverable exactly as before; only newly claimed attempts receive a
// durable deadline and lease fence.
fn migrate_goal_task_attempt_deadline_leases(mut db sqlite.DB) ! {
	db.begin()!
	defer { db.rollback() or {} }
	add_column_if_missing(&db, 'goal_task_attempts', 'effective_deadline', "TEXT NOT NULL DEFAULT ''")!
	add_column_if_missing(&db, 'goal_task_attempts', 'lease_expires_at', "TEXT NOT NULL DEFAULT ''")!
	add_column_if_missing(&db, 'goal_task_attempts', 'lease_generation', 'INTEGER NOT NULL DEFAULT 0 CHECK (lease_generation >= 0)')!
	db.exec('CREATE INDEX IF NOT EXISTS idx_goal_task_attempt_leases ON goal_task_attempts(status, lease_expires_at)')!
	db.exec('INSERT OR IGNORE INTO schema_migrations (version) VALUES (41)')!
	db.commit()!
}

fn migrate_goal_task_session_operation_index(mut db sqlite.DB) ! {
	db.begin()!
	defer { db.rollback() or {} }
	db.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_goal_task_attempts_session_operation ON goal_task_attempts(session_operation_id) WHERE session_operation_id != ''")!
	db.exec('INSERT OR IGNORE INTO schema_migrations (version) VALUES (38)')!
	db.commit()!
}

// SQLite does not allow a CHECK constraint to be widened in place. Rebuild the
// goal task tables while preserving every attempt/worktree row so an upgrade
// can represent the post-worker, pre-receipt verifying state durably.
fn migrate_goal_task_verifying_state(mut db sqlite.DB) ! {
	db.begin()!
	defer { db.rollback() or {} }
	db.exec('DROP INDEX IF EXISTS idx_goal_task_attempts_status')!
	db.exec('DROP INDEX IF EXISTS idx_goal_task_attempts_session_operation')!
	db.exec('ALTER TABLE goal_task_attempt_workspaces RENAME TO goal_task_attempt_workspaces_v40')!
	db.exec('ALTER TABLE goal_task_attempts RENAME TO goal_task_attempts_v40')!
	db.exec('ALTER TABLE goal_task_states RENAME TO goal_task_states_v40')!
	db.exec("CREATE TABLE goal_task_states (
		goal_id TEXT NOT NULL,
		task_id TEXT NOT NULL,
		status TEXT NOT NULL CHECK (status IN ('pending', 'running', 'verifying', 'succeeded', 'failed', 'uncertain')),
		attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
		owner_pid INTEGER NOT NULL DEFAULT 0,
		owner_start_id TEXT NOT NULL DEFAULT '',
		updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
		PRIMARY KEY (goal_id, task_id),
		FOREIGN KEY (goal_id) REFERENCES goal_admissions(id) ON DELETE CASCADE
	)")!
	db.exec('INSERT INTO goal_task_states (goal_id, task_id, status, attempt_count, owner_pid, owner_start_id, updated_at) SELECT goal_id, task_id, status, attempt_count, owner_pid, owner_start_id, updated_at FROM goal_task_states_v40')!
	db.exec("CREATE TABLE goal_task_attempts (
		goal_id TEXT NOT NULL,
		task_id TEXT NOT NULL,
		attempt INTEGER NOT NULL CHECK (attempt > 0),
		status TEXT NOT NULL CHECK (status IN ('running', 'verifying', 'succeeded', 'failed', 'uncertain')),
		owner_pid INTEGER NOT NULL DEFAULT 0,
		owner_start_id TEXT NOT NULL DEFAULT '',
		started_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
		ended_at TEXT NOT NULL DEFAULT '',
		session_id TEXT NOT NULL DEFAULT '',
		session_operation_id TEXT NOT NULL DEFAULT '',
		fencing_token TEXT NOT NULL DEFAULT '',
		PRIMARY KEY (goal_id, task_id, attempt),
		FOREIGN KEY (goal_id, task_id) REFERENCES goal_task_states(goal_id, task_id) ON DELETE CASCADE
	)")!
	db.exec('INSERT INTO goal_task_attempts (goal_id, task_id, attempt, status, owner_pid, owner_start_id, started_at, ended_at, session_id, session_operation_id, fencing_token) SELECT goal_id, task_id, attempt, status, owner_pid, owner_start_id, started_at, ended_at, session_id, session_operation_id, fencing_token FROM goal_task_attempts_v40')!
	db.exec("CREATE TABLE goal_task_attempt_workspaces (
		goal_id TEXT NOT NULL,
		task_id TEXT NOT NULL,
		attempt INTEGER NOT NULL CHECK (attempt > 0),
		repository_root TEXT NOT NULL,
		worktree_path TEXT NOT NULL,
		base_sha TEXT NOT NULL,
		status TEXT NOT NULL CHECK (status IN ('preparing', 'ready', 'uncertain')),
		created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
		updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
		PRIMARY KEY (goal_id, task_id, attempt),
		UNIQUE (worktree_path),
		FOREIGN KEY (goal_id, task_id, attempt) REFERENCES goal_task_attempts(goal_id, task_id, attempt) ON DELETE CASCADE
	)")!
	db.exec('INSERT INTO goal_task_attempt_workspaces (goal_id, task_id, attempt, repository_root, worktree_path, base_sha, status, created_at, updated_at) SELECT goal_id, task_id, attempt, repository_root, worktree_path, base_sha, status, created_at, updated_at FROM goal_task_attempt_workspaces_v40')!
	db.exec('CREATE INDEX idx_goal_task_attempts_status ON goal_task_attempts(status)')!
	db.exec("CREATE UNIQUE INDEX idx_goal_task_attempts_session_operation ON goal_task_attempts(session_operation_id) WHERE session_operation_id != ''")!
	db.exec('DROP TABLE goal_task_attempt_workspaces_v40')!
	db.exec('DROP TABLE goal_task_attempts_v40')!
	db.exec('DROP TABLE goal_task_states_v40')!
	db.exec('INSERT INTO schema_migrations (version) VALUES (40)')!
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
	expired_attempts := db.exec("SELECT goal_id, task_id, attempt, session_id, session_operation_id FROM goal_task_attempts WHERE status = 'running' AND effective_deadline != '' AND (julianday(effective_deadline) <= julianday('now') OR julianday(lease_expires_at) <= julianday('now'))")!
	// Lease expiry wins over any separately completed operation receipt. The
	// worker may have finished after losing its lease, so recovery must not
	// promote that ambiguous result to verifying.
	db.exec("UPDATE goal_task_attempts SET status = 'uncertain', ended_at = CURRENT_TIMESTAMP, owner_pid = 0, owner_start_id = '' WHERE status = 'running' AND effective_deadline != '' AND (julianday(effective_deadline) <= julianday('now') OR julianday(lease_expires_at) <= julianday('now'))")!
	db.exec("UPDATE goal_task_attempt_workspaces SET status = 'uncertain', updated_at = CURRENT_TIMESTAMP WHERE status IN ('preparing', 'ready') AND EXISTS (SELECT 1 FROM goal_task_attempts a WHERE a.goal_id = goal_task_attempt_workspaces.goal_id AND a.task_id = goal_task_attempt_workspaces.task_id AND a.attempt = goal_task_attempt_workspaces.attempt AND a.status = 'uncertain')")!
	db.exec("UPDATE goal_task_states SET status = 'uncertain', updated_at = CURRENT_TIMESTAMP, owner_pid = 0, owner_start_id = '' WHERE status = 'running' AND EXISTS (SELECT 1 FROM goal_task_attempts a WHERE a.goal_id = goal_task_states.goal_id AND a.task_id = goal_task_states.task_id AND a.status = 'uncertain')")!
	db.exec("UPDATE session_operations SET status = 'uncertain', outcome = 'uncertain', error = 'The task attempt lease expired before a result was recorded.', updated_at = CURRENT_TIMESTAMP WHERE status IN ('queued', 'running', 'cancelling') AND EXISTS (SELECT 1 FROM goal_task_attempts a WHERE a.session_id = session_operations.session_id AND a.session_operation_id = session_operations.id AND a.status = 'uncertain')")!
	for row in expired_attempts {
		if row.val(3) != '' && row.val(4) != '' {
			db.exec_param_many('INSERT INTO events (type, session_id, data) VALUES (?, ?, ?)', [
				'goal.task_attempt_completed',
				row.val(3),
				json2.encode[GoalTaskEventData](GoalTaskEventData{
					goal_id:      row.val(0)
					task_id:      row.val(1)
					attempt:      row.val(2).int()
					operation_id: row.val(4)
					status:       'uncertain'
					outcome:      'uncertain'
					error:        'The task attempt lease expired before a result was recorded.'
				}),
			])!
		}
	}
	// A verified task state is the durable result of receipt validation. Its
	// worker attempt intentionally remains `verifying` until Goal acceptance;
	// missing or expired verifier leases must not undo that result on restart.
	verification_expired := db.exec("SELECT a.goal_id, a.task_id, a.attempt, a.session_id, a.session_operation_id, COALESCE(v.fencing_token, ''), COALESCE(v.generation, 0) FROM goal_task_attempts a JOIN goal_task_states s ON s.goal_id = a.goal_id AND s.task_id = a.task_id LEFT JOIN goal_task_verification_leases v ON v.goal_id = a.goal_id AND v.task_id = a.task_id AND v.attempt = a.attempt WHERE a.status = 'verifying' AND s.status != 'verified' AND (v.generation IS NULL OR julianday(v.verification_deadline) IS NULL OR julianday(v.lease_expires_at) IS NULL OR julianday(v.verification_deadline) <= julianday('now') OR julianday(v.lease_expires_at) <= julianday('now'))")!
	for row in verification_expired {
		if row.val(5) != '' && row.val(6).int() > 0 {
			db.exec_param_many('DELETE FROM goal_task_verification_leases WHERE goal_id = ? AND task_id = ? AND attempt = ? AND fencing_token = ? AND generation = ?', [
				row.val(0),
				row.val(1),
				row.val(2),
				row.val(5),
				row.val(6),
			])!
			if db.get_affected_rows_count() != 1 {
				return error('unable to recover expired verification lease fence')
			}
		}
		db.exec_param_many("UPDATE goal_task_attempts SET status = 'uncertain', ended_at = CURRENT_TIMESTAMP WHERE goal_id = ? AND task_id = ? AND attempt = ? AND status = 'verifying'", [
			row.val(0),
			row.val(1),
			row.val(2),
		])!
		if db.get_affected_rows_count() != 1 {
			return error('unable to recover expired verification attempt')
		}
		db.exec_param_many("UPDATE goal_task_states SET status = 'uncertain', updated_at = CURRENT_TIMESTAMP WHERE goal_id = ? AND task_id = ? AND status = 'verifying'", [
			row.val(0),
			row.val(1),
		])!
		if db.get_affected_rows_count() != 1 {
			return error('unable to recover expired verification state')
		}
		db.exec_param_many("UPDATE goal_task_attempt_workspaces SET status = 'uncertain', updated_at = CURRENT_TIMESTAMP WHERE goal_id = ? AND task_id = ? AND attempt = ? AND status IN ('preparing', 'ready')", [
			row.val(0),
			row.val(1),
			row.val(2),
		])!
		if row.val(3) != '' && row.val(4) != '' {
			db.exec_param_many('INSERT INTO events (type, session_id, data) VALUES (?, ?, ?)', [
				'goal.task_attempt_completed',
				row.val(3),
				json2.encode[GoalTaskEventData](GoalTaskEventData{
					goal_id:      row.val(0)
					task_id:      row.val(1)
					attempt:      row.val(2).int()
					operation_id: row.val(4)
					status:       'uncertain'
					outcome:      'uncertain'
					error:        'The verification lease expired before a receipt was recorded.'
				}),
			])!
		}
	}
	interrupted_attempts := db.exec("SELECT a.goal_id, a.task_id, a.attempt, a.owner_pid, a.owner_start_id, a.session_id, a.session_operation_id, COALESCE(o.status, ''), COALESCE(o.outcome, '') FROM goal_task_attempts AS a LEFT JOIN session_operations AS o ON o.session_id = a.session_id AND o.id = a.session_operation_id WHERE a.status = 'running'")!
	for row in interrupted_attempts {
		owner := goal_task_owner_status(row.val(3).int())
		if row.val(4) == '' || !owner.alive || owner.identity == '' || owner.identity != row.val(4) {
			// The session result and Goal transition are separate durable writes.
			// If shutdown lands between them, the completed canonical operation
			// proves the worker finished; recover only to verifying, never accepted.
			if row.val(5) != '' && row.val(6) != '' && row.val(7) == 'completed'
				&& row.val(8) in ['completed', 'completed_with_denials'] {
				_ = db.exec_param_many("UPDATE goal_task_attempts SET status = 'verifying', ended_at = CURRENT_TIMESTAMP, owner_pid = 0, owner_start_id = '' WHERE goal_id = ? AND task_id = ? AND attempt = ? AND status = 'running'", [
					row.val(0),
					row.val(1),
					row.val(2),
				])!
				if db.get_affected_rows_count() == 1 {
					_ = db.exec_param_many("UPDATE goal_task_states SET status = 'verifying', updated_at = CURRENT_TIMESTAMP, owner_pid = 0, owner_start_id = '' WHERE goal_id = ? AND task_id = ? AND status = 'running'", [
						row.val(0),
						row.val(1),
					])!
					if db.get_affected_rows_count() != 1 {
						return error('unable to recover completed goal task state to verifying')
					}
					_ = db.exec_param_many('INSERT INTO events (type, session_id, data) VALUES (?, ?, ?)', [
						'goal.task_attempt_verifying',
						row.val(5),
						json2.encode[GoalTaskEventData](GoalTaskEventData{
							goal_id:      row.val(0)
							task_id:      row.val(1)
							attempt:      row.val(2).int()
							operation_id: row.val(6)
							status:       'verifying'
							outcome:      'completed'
						}),
					])!
				}
				continue
			}
			_ = db.exec_param_many("UPDATE goal_task_attempts SET status = 'uncertain', ended_at = CURRENT_TIMESTAMP WHERE goal_id = ? AND task_id = ? AND attempt = ? AND status = 'running'", [
				row.val(0),
				row.val(1),
				row.val(2),
			])!
			_ = db.exec_param_many("UPDATE goal_task_attempt_workspaces SET status = 'uncertain', updated_at = CURRENT_TIMESTAMP WHERE goal_id = ? AND task_id = ? AND attempt = ? AND status IN ('preparing', 'ready')", [
				row.val(0),
				row.val(1),
				row.val(2),
			])!
			if row.val(5) != '' && row.val(6) != '' {
				_ = db.exec_param_many("UPDATE goal_task_states SET status = 'uncertain', updated_at = CURRENT_TIMESTAMP, owner_pid = 0, owner_start_id = '' WHERE goal_id = ? AND task_id = ? AND status = 'running'", [
					row.val(0),
					row.val(1),
				])!
				_ = db.exec_param_many("UPDATE session_operations SET status = 'uncertain', outcome = 'uncertain', error = 'The server stopped before this task attempt reached a recorded result.', updated_at = CURRENT_TIMESTAMP WHERE session_id = ? AND id = ? AND status IN ('queued', 'running', 'cancelling')", [
					row.val(5),
					row.val(6),
				])!
				if db.get_affected_rows_count() == 1 {
					_ = db.exec_param_many('INSERT INTO events (type, session_id, data) VALUES (?, ?, ?)', [
						'goal.task_attempt_completed',
						row.val(5),
						json2.encode[GoalTaskEventData](GoalTaskEventData{
							goal_id:      row.val(0)
							task_id:      row.val(1)
							attempt:      row.val(2).int()
							operation_id: row.val(6)
							status:       'uncertain'
							outcome:      'uncertain'
							error:        'The server stopped before this task attempt reached a recorded result.'
						}),
					])!
				}
			}
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
	attempt_rows := store.db.exec_param_many('SELECT attempt, status, started_at, ended_at, effective_deadline, lease_expires_at, lease_generation FROM goal_task_attempts WHERE goal_id = ? AND task_id = ? ORDER BY attempt', [
		goal_id,
		task_id,
	])!
	store.db.commit()!
	mut attempts := []GoalTaskAttemptProjection{}
	for row in attempt_rows {
		attempts << GoalTaskAttemptProjection{
			attempt:            row.val(0).int()
			status:             goal_task_attempt_status_from_db(row.val(1))!.str()
			started_at:         row.val(2)
			ended_at:           row.val(3)
			effective_deadline: row.val(4)
			lease_expires_at:   row.val(5)
			lease_generation:   row.val(6).int()
		}
	}
	return GoalTaskProjectionState{
		status:        goal_task_status_from_db(state.val(0))!.str()
		attempt_count: state.val(1).int()
		attempts:      attempts
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
		attempt_rows := store.db.exec_param_many('SELECT attempt, status, started_at, ended_at, effective_deadline, lease_expires_at, lease_generation FROM goal_task_attempts WHERE goal_id = ? AND task_id = ? ORDER BY attempt', [
			goal_id,
			row.val(0),
		])!
		mut attempts := []GoalTaskAttemptProjection{}
		for attempt_row in attempt_rows {
			attempts << GoalTaskAttemptProjection{
				attempt:            attempt_row.val(0).int()
				status:             goal_task_attempt_status_from_db(attempt_row.val(1))!.str()
				started_at:         attempt_row.val(2)
				ended_at:           attempt_row.val(3)
				effective_deadline: attempt_row.val(4)
				lease_expires_at:   attempt_row.val(5)
				lease_generation:   attempt_row.val(6).int()
			}
		}
		states[row.val(0)] = GoalTaskProjectionState{
			status:        goal_task_status_from_db(row.val(1))!.str()
			attempt_count: row.val(2).int()
			attempts:      attempts
		}
	}
	store.db.commit()!
	return states
}

// claim_goal_task atomically claims only a pending task whose dependencies have
// succeeded and whose goal-wide attempt budget has not been exhausted. It is a
// state transition only; it never starts a worker or performs task effects.
fn (mut store Store) claim_goal_task(goal_id string, task_id string) !GoalTaskProjectionState {
	claim := store.claim_goal_task_internal(goal_id, task_id, '', false)!
	return claim.state
}

// Linked claims are an internal storage API until task workers exist. The
// supplied session must already exist; the operation and attempt are created
// atomically, and only the returned fencing token may complete this attempt.
fn (mut store Store) claim_goal_task_for_session(goal_id string, task_id string,
	session_id string) !GoalTaskClaim {
	if session_id.trim_space().len == 0 {
		return error('session identifier is required for linked goal task claim')
	}
	return store.claim_goal_task_internal(goal_id, task_id, session_id, false)
}

// A dispatcher claim deliberately has no session during the short worktree
// creation window. It is separate from the linked-session API so existing
// callers cannot accidentally create an unlinked attempt.
fn (mut store Store) claim_goal_task_for_dispatch(goal_id string, task_id string) !GoalTaskClaim {
	return store.claim_goal_task_internal(goal_id, task_id, '', true)
}

fn (mut store Store) claim_goal_task_internal(goal_id string, task_id string,
	session_id string, force_fencing bool) !GoalTaskClaim {
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
	if session_id != '' {
		sessions := store.db.exec_param_many('SELECT id FROM sessions WHERE id = ?', [session_id])!
		if sessions.len != 1 {
			return error('session not found')
		}
	}
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
	claimed_at := time.now()
	budget_deadline := claimed_at.add(time.Duration(goal.budget.wall_seconds) * time.second)
	goal_deadline := if goal.deadline.trim_space() == '' {
		budget_deadline
	} else {
		time.parse_rfc3339(goal.deadline)!
	}
	effective_deadline := if goal_deadline < budget_deadline {
		goal_deadline
	} else {
		budget_deadline
	}
	if effective_deadline <= claimed_at {
		return error('goal task deadline has expired')
	}
	deadline_text := effective_deadline.format_rfc3339()
	initial_lease_deadline := claimed_at.add(time.Duration(goal_task_initial_lease_seconds) * time.second)
	lease_text := (if initial_lease_deadline < effective_deadline {
		initial_lease_deadline
	} else {
		effective_deadline
	}).format_rfc3339()
	mut session_operation_id := ''
	// Every claim gets a fencing token, including the short unlinked window
	// used by the local dispatcher while it creates the isolated worktree and
	// session. This prevents a stale dispatcher from attaching an operation.
	_ = force_fencing
	fencing_token := uuid.new_v4().str()
	if session_id != '' {
		session_operation_id = uuid.new_v4().str()
		_ = store.db.exec_param_many("INSERT INTO session_operations (id, session_id, status, request_json, queue_order) VALUES (?, ?, 'running', '', (SELECT COALESCE(MAX(queue_order), 0) + 1 FROM session_operations WHERE session_id = ?))", [
			session_operation_id,
			session_id,
			session_id,
		])!
		_ = store.db.exec_param_many('INSERT INTO events (type, session_id, data) VALUES (?, ?, ?)', [
			'goal.task_attempt_started',
			session_id,
			json2.encode[GoalTaskEventData](GoalTaskEventData{
				goal_id:      goal_id
				task_id:      task_id
				attempt:      attempt.int()
				operation_id: session_operation_id
				status:       'running'
			}),
		])!
	}
	_ = store.db.exec_param_many("INSERT INTO goal_task_attempts (goal_id, task_id, attempt, status, owner_pid, owner_start_id, session_id, session_operation_id, fencing_token, effective_deadline, lease_expires_at, lease_generation) VALUES (?, ?, ?, 'running', ?, ?, ?, ?, ?, ?, ?, 1)", [
		goal_id,
		task_id,
		attempt,
		pid,
		owner_start_id,
		session_id,
		session_operation_id,
		fencing_token,
		deadline_text,
		lease_text,
	])!
	store.db.commit()!
	return GoalTaskClaim{
		state:                store.goal_task_state_unlocked(goal_id, task_id)!
		session_operation_id: session_operation_id
		fencing_token:        fencing_token
		lease_generation:     1
		effective_deadline:   deadline_text
		lease_expires_at:     lease_text
	}
}

fn (mut store Store) renew_goal_task_attempt_lease(goal_id string, task_id string, attempt int,
	fencing_token string, generation int, lease_seconds int) !GoalTaskLease {
	if fencing_token.len == 0 || generation <= 0 || lease_seconds <= 0 {
		return error('goal task lease renewal requires token, generation and duration')
	}
	store.mu.lock()
	defer { store.mu.unlock() }
	store.db.exec('BEGIN IMMEDIATE')!
	defer { store.db.rollback() or {} }
	rows := store.db.exec_param_many('SELECT status, effective_deadline, lease_expires_at, lease_generation, fencing_token FROM goal_task_attempts WHERE goal_id = ? AND task_id = ? AND attempt = ?', [
		goal_id,
		task_id,
		attempt.str(),
	])!
	if rows.len != 1 || rows[0].val(0) != 'running' || rows[0].val(3).int() != generation || rows[0].val(4) != fencing_token {
		return error('goal task lease is stale or not running')
	}
	now := time.now()
	effective := time.parse_rfc3339(rows[0].val(1)) or { return error('goal task effective deadline is invalid') }
	lease_expiry := time.parse_rfc3339(rows[0].val(2)) or { return error('goal task lease expiry is invalid') }
	if now >= lease_expiry {
		return error('goal task lease has expired')
	}
	if now >= effective {
		return error('goal task attempt deadline has expired')
	}
	requested := now.add(time.Duration(lease_seconds) * time.second)
	expires := if requested < effective { requested } else { effective }
	new_generation := generation + 1
	new_token := uuid.new_v4().str()
	store.db.exec_param_many("UPDATE goal_task_attempts SET lease_expires_at = ?, lease_generation = ?, fencing_token = ? WHERE goal_id = ? AND task_id = ? AND attempt = ? AND status = 'running' AND fencing_token = ? AND lease_generation = ?", [
		expires.format_rfc3339(),
		new_generation.str(),
		new_token,
		goal_id,
		task_id,
		attempt.str(),
		fencing_token,
		generation.str(),
	])!
	if store.db.get_affected_rows_count() != 1 {
		return error('goal task lease changed while renewing')
	}
	store.db.commit()!
	return GoalTaskLease{ effective_deadline: effective.format_rfc3339(), lease_expires_at: expires.format_rfc3339(), generation: new_generation, fencing_token: new_token }
}

// linked_running_goal_task_lease discovers the sole goal-task attempt linked
// to an operation. Ordinary session operations have no such row and therefore
// deliberately return none; they do not start a heartbeat.
fn (mut store Store) linked_running_goal_task_lease(operation_id string) !GoalTaskLeaseLookup {
	if operation_id.trim_space().len == 0 {
		return GoalTaskLeaseLookup{}
	}
	store.mu.lock()
	defer { store.mu.unlock() }
	rows := store.db.exec_param_many('SELECT goal_id, task_id, attempt, status, fencing_token, lease_generation FROM goal_task_attempts WHERE session_operation_id = ?', [
		operation_id,
	])!
	if rows.len == 0 {
		return GoalTaskLeaseLookup{}
	}
	if rows.len != 1 {
		return error('goal task operation has multiple running lease links')
	}
	if rows[0].val(3) != 'running' {
		return error('goal task operation is linked to a non-running attempt')
	}
	if rows[0].val(4).len == 0 || rows[0].val(5).int() <= 0 {
		return error('goal task operation lease link is malformed')
	}
	return GoalTaskLeaseLookup{
		linked:  true
		binding: GoalTaskLeaseBinding{
			goal_id:       rows[0].val(0)
			task_id:       rows[0].val(1)
			attempt:       rows[0].val(2).int()
			fencing_token: rows[0].val(4)
			generation:    rows[0].val(5).int()
		}
	}
}

fn (mut store Store) validate_goal_task_attempt_lease(binding GoalTaskLeaseBinding) ! {
	store.mu.lock()
	defer { store.mu.unlock() }
	rows := store.db.exec_param_many('SELECT status, effective_deadline, lease_expires_at, fencing_token, lease_generation FROM goal_task_attempts WHERE goal_id = ? AND task_id = ? AND attempt = ?', [
		binding.goal_id,
		binding.task_id,
		binding.attempt.str(),
	])!
	if rows.len != 1 || rows[0].val(0) != 'running' || rows[0].val(3) != binding.fencing_token
		|| rows[0].val(4).int() != binding.generation {
		return error('goal task lease is stale or not running')
	}
	now := time.now()
	lease_expiry := time.parse_rfc3339(rows[0].val(2)) or {
		return error('goal task lease expiry is invalid')
	}
	if now >= lease_expiry {
		return error('goal task lease has expired')
	}
	effective := time.parse_rfc3339(rows[0].val(1)) or {
		return error('goal task effective deadline is invalid')
	}
	if now >= effective {
		return error('goal task attempt deadline has expired')
	}
}

fn (mut store Store) expire_goal_task_attempt_lease(goal_id string, task_id string, attempt int,
	fencing_token string, generation int) !bool {
	if fencing_token.len == 0 || generation <= 0 {
		return error('goal task lease expiry requires token and generation')
	}
	store.mu.lock()
	defer { store.mu.unlock() }
	store.db.exec('BEGIN IMMEDIATE')!
	defer { store.db.rollback() or {} }
	rows := store.db.exec_param_many('SELECT status, lease_expires_at, effective_deadline, lease_generation, fencing_token, session_id, session_operation_id FROM goal_task_attempts WHERE goal_id = ? AND task_id = ? AND attempt = ?', [
		goal_id,
		task_id,
		attempt.str(),
	])!
	if rows.len != 1 || rows[0].val(0) != 'running' || rows[0].val(3).int() != generation || rows[0].val(4) != fencing_token {
		return error('goal task lease is stale or not running')
	}
	now := time.now()
	lease_expiry := time.parse_rfc3339(rows[0].val(1)) or { return error('goal task lease expiry is invalid') }
	effective := time.parse_rfc3339(rows[0].val(2)) or { return error('goal task effective deadline is invalid') }
	if now < lease_expiry && now < effective {
		return error('goal task lease has not expired')
	}
	store.db.exec_param_many("UPDATE goal_task_attempts SET status = 'uncertain', ended_at = CURRENT_TIMESTAMP, owner_pid = 0, owner_start_id = '' WHERE goal_id = ? AND task_id = ? AND attempt = ? AND status = 'running' AND fencing_token = ? AND lease_generation = ?", [
		goal_id,
		task_id,
		attempt.str(),
		fencing_token,
		generation.str(),
	])!
	if store.db.get_affected_rows_count() != 1 {
		return error('goal task attempt changed while expiring lease')
	}
	store.db.exec_param_many("UPDATE goal_task_states SET status = 'uncertain', updated_at = CURRENT_TIMESTAMP, owner_pid = 0, owner_start_id = '' WHERE goal_id = ? AND task_id = ? AND status = 'running'", [
		goal_id,
		task_id,
	])!
	if store.db.get_affected_rows_count() != 1 {
		return error('goal task state changed while expiring lease')
	}
	store.db.exec_param_many("UPDATE goal_task_attempt_workspaces SET status = 'uncertain', updated_at = CURRENT_TIMESTAMP WHERE goal_id = ? AND task_id = ? AND attempt = ? AND status IN ('preparing', 'ready')", [
		goal_id,
		task_id,
		attempt.str(),
	])!
	workspace_rows := store.db.exec_param_many('SELECT status FROM goal_task_attempt_workspaces WHERE goal_id = ? AND task_id = ? AND attempt = ?', [
		goal_id,
		task_id,
		attempt.str(),
	])!
	if workspace_rows.len == 1 && workspace_rows[0].val(0) != 'uncertain' {
		return error('goal task workspace changed while expiring lease')
	}
	if rows[0].val(6) != '' {
		store.db.exec_param_many("UPDATE session_operations SET status = 'uncertain', outcome = 'uncertain', error = 'The task attempt lease expired before a result was recorded.', updated_at = CURRENT_TIMESTAMP WHERE session_id = ? AND id = ? AND status IN ('queued', 'running', 'cancelling')", [
			rows[0].val(5),
			rows[0].val(6),
		])!
		if store.db.get_affected_rows_count() != 1 {
			operation_rows := store.db.exec_param_many('SELECT status FROM session_operations WHERE session_id = ? AND id = ?', [
				rows[0].val(5),
				rows[0].val(6),
			])!
			// A terminal canonical operation is preserved: it may have recorded
			// its result before lease expiry, but the attempt itself is still
			// fenced and therefore uncertain until independently reconciled.
			if operation_rows.len != 1 || operation_rows[0].val(0) !in ['completed', 'failed',
				'cancelled', 'uncertain'] {
				return error('linked operation changed while expiring lease')
			}
		}
		store.db.exec_param_many('INSERT INTO events (type, session_id, data) VALUES (?, ?, ?)', [
			'goal.task_attempt_completed',
			rows[0].val(5),
			json2.encode[GoalTaskEventData](GoalTaskEventData{
				goal_id:      goal_id
				task_id:      task_id
				attempt:      attempt
				operation_id: rows[0].val(6)
				status:       'uncertain'
				outcome:      'uncertain'
				error:        'The task attempt lease expired before a result was recorded.'
			}),
		])!
	}
	store.db.commit()!
	return true
}

// attach_goal_task_attempt_session closes the dispatcher handoff after the
// exact-base worktree exists. The session is created by the caller with its
// directory already pointing at that worktree; this method only links the
// durable queued operation under the claim's fencing token.
fn (mut store Store) attach_goal_task_attempt_session(goal_id string, task_id string,
	attempt int, fencing_token string, session_id string, request_json string) !string {
	if fencing_token.len == 0 || session_id.len == 0 || request_json.trim_space().len == 0 {
		return error('goal task dispatch link requires fencing, session and request')
	}
	input := json2.decode[ChatMessageInput](request_json) or {
		return error('goal task dispatch request is invalid')
	}
	validate_messages([ChatMessage{ role: 'user', content: input.content }])!
	store.mu.lock()
	defer { store.mu.unlock() }
	store.db.begin()!
	defer { store.db.rollback() or {} }
	rows := store.db.exec_param_many('SELECT status, session_id, session_operation_id, fencing_token FROM goal_task_attempts WHERE goal_id = ? AND task_id = ? AND attempt = ?', [
		goal_id,
		task_id,
		attempt.str(),
	])!
	if rows.len != 1 || rows[0].val(0) != 'running' || rows[0].val(3) != fencing_token
		|| rows[0].val(1) != '' || rows[0].val(2) != '' {
		return error('goal task attempt is stale or already linked')
	}
	workspaces := store.db.exec_param_many("SELECT worktree_path FROM goal_task_attempt_workspaces WHERE goal_id = ? AND task_id = ? AND attempt = ? AND status = 'ready'", [
		goal_id,
		task_id,
		attempt.str(),
	])!
	if workspaces.len != 1 {
		return error('goal task attempt workspace is not ready')
	}
	sessions := store.db.exec_param('SELECT directory FROM sessions WHERE id = ?', session_id)!
	if sessions.len != 1 {
		return error('session not found')
	}
	if sessions[0].val(0) != workspaces[0].val(0) {
		return error('goal task session directory does not match its isolated worktree')
	}
	operation_id := uuid.new_v4().str()
	store.db.exec_param_many("INSERT INTO session_operations (id, session_id, status, request_json, queue_order) VALUES (?, ?, 'queued', ?, (SELECT COALESCE(MAX(queue_order), 0) + 1 FROM session_operations WHERE session_id = ?))", [
		operation_id,
		session_id,
		request_json,
		session_id,
	])!
	store.db.exec_param_many("UPDATE goal_task_attempts SET session_id = ?, session_operation_id = ? WHERE goal_id = ? AND task_id = ? AND attempt = ? AND status = 'running' AND fencing_token = ?", [
		session_id,
		operation_id,
		goal_id,
		task_id,
		attempt.str(),
		fencing_token,
	])!
	if store.db.get_affected_rows_count() != 1 {
		return error('goal task attempt changed while linking session')
	}
	store.db.exec_param_many('INSERT INTO events (type, session_id, data) VALUES (?, ?, ?)', [
		'goal.task_attempt_started',
		session_id,
		json2.encode[GoalTaskEventData](GoalTaskEventData{
			goal_id:      goal_id
			task_id:      task_id
			attempt:      attempt
			operation_id: operation_id
			status:       'queued'
		}),
	])!
	store.db.commit()!
	return operation_id
}

// complete_goal_task_attempt records an explicit result. Failed attempts return
// the task to pending while budget remains; uncertain results are never retried.
fn (mut store Store) complete_goal_task_attempt(goal_id string, task_id string, attempt int, result GoalTaskResult) ! {
	store.mu.lock()
	defer { store.mu.unlock() }
	store.db.exec('BEGIN IMMEDIATE')!
	defer { store.db.rollback() or {} }
	rows := store.db.exec_param_many('SELECT fencing_token FROM goal_task_attempts WHERE goal_id = ? AND task_id = ? AND attempt = ?', [
		goal_id,
		task_id,
		attempt.str(),
	])!
	if rows.len != 1 {
		return error('goal task attempt not found')
	}
	store.complete_goal_task_attempt_in_transaction(goal_id, task_id, attempt, rows[0].val(0), result)!
	store.db.commit()!
}

fn (mut store Store) complete_linked_goal_task_attempt(goal_id string, task_id string, attempt int,
	fencing_token string, result GoalTaskResult) ! {
	if fencing_token.len == 0 {
		return error('goal task fencing token is required')
	}
	store.mu.lock()
	defer { store.mu.unlock() }
	store.db.exec('BEGIN IMMEDIATE')!
	defer { store.db.rollback() or {} }
	store.complete_goal_task_attempt_in_transaction(goal_id, task_id, attempt, fencing_token, result)!
	store.db.commit()!
}

// reconcile_goal_task_operation closes a dispatched attempt when the canonical
// session worker records its terminal operation result. A successful worker
// result is deliberately only a verifying transition: an independent receipt
// bound to the candidate SHA is still required before succeeded. Missing links
// are a no-op so ordinary session turns retain their existing behavior.
fn (mut store Store) reconcile_goal_task_operation(operation_id string, result GoalTaskResult) ! {
	goal_result := if result == .succeeded {
		GoalTaskResult.verifying
	} else {
		result
	}
	store.mu.lock()
	defer { store.mu.unlock() }
	store.db.exec('BEGIN IMMEDIATE')!
	defer { store.db.rollback() or {} }
	rows := store.db.exec_param("SELECT goal_id, task_id, attempt, fencing_token FROM goal_task_attempts WHERE session_operation_id = ? AND status = 'running'", operation_id)!
	if rows.len == 0 {
		store.db.commit()!
		return
	}
	store.complete_goal_task_attempt_in_transaction(rows[0].val(0), rows[0].val(1), rows[0].val(2).int(), rows[0].val(3), goal_result)!
	store.db.commit()!
}

fn (mut store Store) complete_goal_task_attempt_in_transaction(goal_id string, task_id string,
	attempt int, fencing_token string, result GoalTaskResult) ! {
	lease_rows := store.db.exec_param_many("SELECT effective_deadline, lease_expires_at, session_id, session_operation_id, fencing_token, lease_generation FROM goal_task_attempts WHERE goal_id = ? AND task_id = ? AND attempt = ? AND status = 'running'", [
		goal_id,
		task_id,
		attempt.str(),
	])!
	if lease_rows.len != 1 {
		return error('goal task attempt is not running')
	}
	if lease_rows[0].val(4) != fencing_token {
		return error('goal task attempt is not running or fencing token is stale')
	}
	now := time.now()
	effective := time.parse_rfc3339(lease_rows[0].val(0)) or { return error('goal task effective deadline is invalid') }
	lease_expiry := time.parse_rfc3339(lease_rows[0].val(1)) or { return error('goal task lease expiry is invalid') }
	if now >= effective || now >= lease_expiry {
		store.db.exec_param_many("UPDATE goal_task_attempts SET status = 'uncertain', ended_at = CURRENT_TIMESTAMP, owner_pid = 0, owner_start_id = '' WHERE goal_id = ? AND task_id = ? AND attempt = ? AND status = 'running'", [
			goal_id,
			task_id,
			attempt.str(),
		])!
		store.db.exec_param_many("UPDATE goal_task_states SET status = 'uncertain', updated_at = CURRENT_TIMESTAMP, owner_pid = 0, owner_start_id = '' WHERE goal_id = ? AND task_id = ? AND status = 'running'", [
			goal_id,
			task_id,
		])!
		store.db.exec_param_many("UPDATE goal_task_attempt_workspaces SET status = 'uncertain', updated_at = CURRENT_TIMESTAMP WHERE goal_id = ? AND task_id = ? AND attempt = ? AND status IN ('preparing', 'ready')", [
			goal_id,
			task_id,
			attempt.str(),
		])!
		if lease_rows[0].val(3) != '' {
			store.db.exec_param_many("UPDATE session_operations SET status = 'uncertain', outcome = 'uncertain', error = 'The task attempt lease expired before a result was recorded.', updated_at = CURRENT_TIMESTAMP WHERE session_id = ? AND id = ? AND status IN ('queued', 'running', 'cancelling')", [
				lease_rows[0].val(2),
				lease_rows[0].val(3),
			])!
			store.db.exec_param_many('INSERT INTO events (type, session_id, data) VALUES (?, ?, ?)', [
				'goal.task_attempt_completed',
				lease_rows[0].val(2),
				json2.encode[GoalTaskEventData](GoalTaskEventData{
					goal_id:      goal_id
					task_id:      task_id
					attempt:      attempt
					operation_id: lease_rows[0].val(3)
					status:       'uncertain'
					outcome:      'uncertain'
					error:        'The task attempt lease expired before a result was recorded.'
				}),
			])!
		}
		return error('goal task lease has expired; result is uncertain')
	}
	_ = store.db.exec_param_many("UPDATE goal_task_attempts SET status = ?, ended_at = CURRENT_TIMESTAMP WHERE goal_id = ? AND task_id = ? AND attempt = ? AND status = 'running' AND fencing_token = ?", [
		result.str(),
		goal_id,
		task_id,
		attempt.str(),
		fencing_token,
	])!
	if store.db.get_affected_rows_count() != 1 {
		return error('goal task attempt is not running or fencing token is stale')
	}
	// Generic completion has no verifier provenance or candidate-SHA proof. Keep
	// success reserved for the future receipt-backed transition.
	if result == .succeeded {
		return error('goal task success requires an independent verification receipt')
	}
	linked := store.db.exec_param_many('SELECT session_id, session_operation_id FROM goal_task_attempts WHERE goal_id = ? AND task_id = ? AND attempt = ?', [
		goal_id,
		task_id,
		attempt.str(),
	])!
	if linked.len != 1 {
		return error('goal task attempt link not found')
	}
	if linked[0].val(1) != '' {
		op_status := match result {
			.verifying { 'completed' }
			.succeeded { 'completed' }
			.failed { 'failed' }
			.uncertain { 'uncertain' }
		}
		op_outcome := match result {
			.verifying { 'completed' }
			.succeeded { 'completed' }
			.failed { 'failed' }
			.uncertain { 'uncertain' }
		}
		if linked[0].val(0).len == 0 {
			return error('linked goal task session is invalid')
		}
		sessions := store.db.exec_param_many('SELECT id FROM sessions WHERE id = ?', [linked[0].val(0)])!
		if sessions.len > 0 {
			operations := store.db.exec_param_many('SELECT status FROM session_operations WHERE session_id = ? AND id = ?', [
				linked[0].val(0),
				linked[0].val(1),
			])!
			if operations.len != 1 {
				return error('linked goal task session operation not found')
			}
			if operations[0].val(0) in ['queued', 'running', 'cancelling'] {
				_ = store.db.exec_param_many("UPDATE session_operations SET status = ?, outcome = ?, error = ?, updated_at = CURRENT_TIMESTAMP WHERE session_id = ? AND id = ? AND status IN ('queued', 'running', 'cancelling')", [
					op_status,
					op_outcome,
					if result == .uncertain { 'The task attempt result is uncertain.' } else { '' },
					linked[0].val(0),
					linked[0].val(1),
				])!
			} else if operations[0].val(0) !in ['completed', 'failed', 'uncertain', 'cancelled'] {
				return error('linked goal task session operation has an invalid status')
			}
			// The canonical session worker may have already recorded the terminal
			// operation outcome. In that case only the goal attempt transition is
			// still needed.
			_ = store.db.exec_param_many('INSERT INTO events (type, session_id, data) VALUES (?, ?, ?)', [
				'goal.task_attempt_completed',
				linked[0].val(0),
				json2.encode[GoalTaskEventData](GoalTaskEventData{
					goal_id:      goal_id
					task_id:      task_id
					attempt:      attempt
					operation_id: linked[0].val(1)
					status:       result.str()
					outcome:      op_outcome
					error:        if result == .uncertain {
						'The task attempt result is uncertain.'
					} else {
						''
					}
				}),
			])!
		}
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
		.verifying { GoalTaskStatus.verifying }
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
	if result == .uncertain {
		_ = store.db.exec_param_many("UPDATE goal_task_attempt_workspaces SET status = 'uncertain', updated_at = CURRENT_TIMESTAMP WHERE goal_id = ? AND task_id = ? AND attempt = ? AND status IN ('preparing', 'ready')", [
			goal_id,
			task_id,
			attempt.str(),
		])!
	}
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
	attempt_rows := store.db.exec_param_many('SELECT attempt, status, started_at, ended_at, effective_deadline, lease_expires_at, lease_generation FROM goal_task_attempts WHERE goal_id = ? AND task_id = ? ORDER BY attempt', [
		goal_id,
		task_id,
	])!
	store.db.commit()!
	mut attempts := []GoalTaskAttemptProjection{}
	for row in attempt_rows {
		attempts << GoalTaskAttemptProjection{
			attempt:            row.val(0).int()
			status:             goal_task_attempt_status_from_db(row.val(1))!.str()
			started_at:         row.val(2)
			ended_at:           row.val(3)
			effective_deadline: row.val(4)
			lease_expires_at:   row.val(5)
			lease_generation:   row.val(6).int()
		}
	}
	return GoalTaskProjectionState{
		status:        goal_task_status_from_db(state.val(0))!.str()
		attempt_count: state.val(1).int()
		attempts:      attempts
	}
}
