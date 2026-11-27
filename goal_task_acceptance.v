module main

import db.sqlite
import json2
import strconv
import time
import veb

const max_goal_task_acceptance_request_bytes = 4_096
const goal_task_acceptance_actor = 'local-api-bearer'
const goal_task_acceptance_check = 'candidate_commit_descendant_and_declared_paths'

// GoalTaskAcceptanceReceipt records the explicit local operator decision that
// promotes one exact, independently reviewed candidate to succeeded. The
// authenticated local API has a single bearer principal today, so actor is a
// stable capability label rather than a claimed human identity.
pub struct GoalTaskAcceptanceReceipt {
pub:
	goal_id          string
	task_id          string
	attempt          int
	repository       string
	base_sha         string
	candidate_sha    string
	decision         string
	actor            string
	integrity_checks []string
	created_at       string
}

struct GoalTaskAcceptanceRequest {
	attempt       int
	candidate_sha string
	decision      string
}

struct GoalTaskAcceptanceRequestJSON {
	attempt       string
	candidate_sha string
	decision      string
}

struct GoalTaskAcceptanceEvent {
	goal_id       string
	task_id       string
	attempt       int
	candidate_sha string
	decision      string
	actor         string
}

fn migrate_goal_task_acceptances(mut db sqlite.DB) ! {
	db.begin()!
	defer { db.rollback() or {} }
	db.exec("CREATE TABLE IF NOT EXISTS goal_task_acceptances (
		goal_id TEXT NOT NULL,
		task_id TEXT NOT NULL,
		attempt INTEGER NOT NULL CHECK (attempt > 0),
		repository TEXT NOT NULL,
		base_sha TEXT NOT NULL,
		candidate_sha TEXT NOT NULL,
		decision TEXT NOT NULL CHECK (decision = 'accept'),
		actor TEXT NOT NULL,
		checks_json TEXT NOT NULL,
		created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
		PRIMARY KEY (goal_id, task_id, attempt),
		FOREIGN KEY (goal_id, task_id, attempt) REFERENCES goal_task_attempts(goal_id, task_id, attempt) ON DELETE CASCADE
	)")!
	db.exec("CREATE TRIGGER IF NOT EXISTS goal_task_acceptances_no_update BEFORE UPDATE ON goal_task_acceptances BEGIN SELECT RAISE(ABORT, 'goal task acceptances are immutable'); END")!
	db.exec('INSERT OR IGNORE INTO schema_migrations (version) VALUES (45)')!
	db.commit()!
}

fn (mut store Store) accept_goal_task(goal_id string, task_id string, request GoalTaskAcceptanceRequest) !GoalTaskAcceptanceReceipt {
	if request.attempt <= 0 || !valid_goal_sha(request.candidate_sha) || request.decision != 'accept' {
		return error('acceptance conflict: invalid attempt, candidate SHA, or decision')
	}
	store.mu.lock()
	defer { store.mu.unlock() }
	store.db.exec('BEGIN IMMEDIATE')!
	defer { store.db.rollback() or {} }
	prior := store.db.exec_param_many('SELECT x.repository, x.base_sha, x.candidate_sha, x.decision, x.actor, x.checks_json, x.created_at, s.status, a.status, r.repository, r.base_sha, r.candidate_sha, r.verdict, b.status, g.manifest FROM goal_task_acceptances x JOIN goal_task_states s ON s.goal_id = x.goal_id AND s.task_id = x.task_id JOIN goal_task_attempts a ON a.goal_id = x.goal_id AND a.task_id = x.task_id AND a.attempt = x.attempt JOIN goal_task_verification_receipts r ON r.goal_id = x.goal_id AND r.task_id = x.task_id AND r.attempt = x.attempt JOIN goal_task_verifier_bindings b ON b.id = r.binding_id JOIN goal_admissions g ON g.id = x.goal_id WHERE x.goal_id = ? AND x.task_id = ? AND x.attempt = ?', [
		goal_id,
		task_id,
		request.attempt.str(),
	])!
	if prior.len == 1 {
		if prior[0].val(2) != request.candidate_sha || prior[0].val(3) != request.decision {
			return error('acceptance conflict: a different candidate or decision was already accepted')
		}
		if prior[0].val(7) != 'succeeded' || prior[0].val(8) != 'succeeded'
			|| prior[0].val(0) != prior[0].val(9) || prior[0].val(1) != prior[0].val(10)
			|| prior[0].val(2) != prior[0].val(11) || prior[0].val(12) != 'pass'
			|| prior[0].val(13) != 'consumed' {
			return error('stored goal task acceptance no longer matches its terminal state and pass receipt')
		}
		goal := json2.decode[GoalAdmission](prior[0].val(14)) or {
			return error('stored Goal manifest is invalid')
		}
		task := goal_task_by_id(goal, task_id)!
		if task.repository != prior[0].val(0) || task.base_sha != prior[0].val(1) {
			return error('stored goal task acceptance no longer matches the admitted task')
		}
		checks := json2.decode[[]string](prior[0].val(5)) or {
			return error('stored goal task integrity checks are invalid')
		}
		store.db.commit()!
		return GoalTaskAcceptanceReceipt{
			goal_id:          goal_id
			task_id:          task_id
			attempt:          request.attempt
			repository:       prior[0].val(0)
			base_sha:         prior[0].val(1)
			candidate_sha:    prior[0].val(2)
			decision:         prior[0].val(3)
			actor:            prior[0].val(4)
			integrity_checks: checks
			created_at:       prior[0].val(6)
		}
	}
	rows := store.db.exec_param_many("SELECT g.manifest, s.status, a.status, a.session_id, a.session_operation_id, r.repository, r.repository_root, r.worktree_path, r.base_sha, r.candidate_sha, r.verifier_id, r.verifier_version, r.reviewer_run_id, r.lease_generation, r.verdict, w.status, COALESCE(o.status, ''), b.status, w.repository_root, w.worktree_path, w.base_sha FROM goal_admissions g JOIN goal_task_states s ON s.goal_id = g.id JOIN goal_task_attempts a ON a.goal_id = s.goal_id AND a.task_id = s.task_id JOIN goal_task_verification_receipts r ON r.goal_id = a.goal_id AND r.task_id = a.task_id AND r.attempt = a.attempt JOIN goal_task_verifier_bindings b ON b.id = r.binding_id JOIN goal_task_attempt_workspaces w ON w.goal_id = a.goal_id AND w.task_id = a.task_id AND w.attempt = a.attempt LEFT JOIN session_operations o ON o.session_id = a.session_id AND o.id = a.session_operation_id WHERE g.id = ? AND s.task_id = ? AND a.attempt = ?", [
		goal_id,
		task_id,
		request.attempt.str(),
	])!
	if rows.len != 1 {
		return error('acceptance conflict: no acceptance-ready verification receipt exists')
	}
	row := rows[0]
	if row.val(1) != 'verified' || row.val(2) != 'verifying' || row.val(14) != 'pass'
		|| row.val(15) != 'ready' || row.val(16) != 'completed' || row.val(17) != 'consumed'
		|| row.val(4).len == 0
		|| row.val(9) != request.candidate_sha {
		return error('acceptance conflict: task is not verified for this candidate and completed worker operation')
	}
	lease := store.db.exec_param_many('SELECT 1 FROM goal_task_verification_leases WHERE goal_id = ? AND task_id = ? AND attempt = ?', [
		goal_id,
		task_id,
		request.attempt.str(),
	])!
	if lease.len != 0 {
		return error('acceptance conflict: verification lease must be consumed before acceptance')
	}
	goal := json2.decode[GoalAdmission](row.val(0)) or {
		return error('stored Goal manifest is invalid')
	}
	if goal.id != goal_id {
		return error('stored Goal identity does not match acceptance request')
	}
	task := goal_task_by_id(goal, task_id)!
	if task.repository != row.val(5) || task.base_sha != row.val(8) {
		return error('verification receipt does not match the admitted task')
	}
	mut admitted_root := ''
	for repository in goal.authorized_repositories {
		if task.repository.to_lower() == '${repository.owner}/${repository.name}'.to_lower() {
			admitted_root = repository.path
			break
		}
	}
	if admitted_root.len == 0 || row.val(18) != row.val(6) || row.val(19) != row.val(7)
		|| row.val(20) != row.val(8) || row.val(6) != admitted_root {
		return error('verification receipt does not match the persisted attempt workspace')
	}
	workspace := GoalTaskWorktree{
		goal_id:         goal_id
		task_id:         task_id
		attempt:         request.attempt
		repository_root: row.val(6)
		path:            row.val(7)
		base_sha:        row.val(8)
		status:          row.val(15)
	}
	deadline := time.now().add(10 * time.second)
	observation := observe_goal_task_candidate_commit(workspace, task, request.candidate_sha,
		deadline) or { return error('acceptance conflict: candidate commit failed integrity checks: ${err.msg()}') }
	if observation.base_sha != row.val(8) || observation.candidate_sha != row.val(9) {
		return error('acceptance conflict: candidate commit changed after independent review')
	}
	checks := [goal_task_acceptance_check]
	checks_json := json2.encode[[]string](checks)
	store.db.exec_param_many("INSERT INTO goal_task_acceptances (goal_id, task_id, attempt, repository, base_sha, candidate_sha, decision, actor, checks_json) VALUES (?, ?, ?, ?, ?, ?, 'accept', ?, ?)", [
		goal_id,
		task_id,
		request.attempt.str(),
		row.val(5),
		row.val(8),
		row.val(9),
		goal_task_acceptance_actor,
		checks_json,
	])!
	if store.db.get_affected_rows_count() != 1 {
		return error('goal task acceptance record was not inserted')
	}
	store.db.exec_param_many("UPDATE goal_task_attempts SET status = 'succeeded', ended_at = CURRENT_TIMESTAMP, owner_pid = 0, owner_start_id = '' WHERE goal_id = ? AND task_id = ? AND attempt = ? AND status = 'verifying'", [
		goal_id,
		task_id,
		request.attempt.str(),
	])!
	if store.db.get_affected_rows_count() != 1 {
		return error('acceptance conflict: goal task attempt changed before acceptance')
	}
	store.db.exec_param_many("UPDATE goal_task_states SET status = 'succeeded', updated_at = CURRENT_TIMESTAMP, owner_pid = 0, owner_start_id = '' WHERE goal_id = ? AND task_id = ? AND status = 'verified'", [
		goal_id,
		task_id,
	])!
	if store.db.get_affected_rows_count() != 1 {
		return error('acceptance conflict: goal task changed before acceptance')
	}
	store.db.exec_param_many('INSERT INTO events (type, session_id, data) VALUES (?, ?, ?)', [
		'goal.task_accepted',
		row.val(3),
		json2.encode[GoalTaskAcceptanceEvent](GoalTaskAcceptanceEvent{
			goal_id:       goal_id
			task_id:       task_id
			attempt:       request.attempt
			candidate_sha: row.val(9)
			decision:      request.decision
			actor:         goal_task_acceptance_actor
		}),
	])!
	receipt_rows := store.db.exec_param_many('SELECT repository, base_sha, candidate_sha, decision, actor, checks_json, created_at FROM goal_task_acceptances WHERE goal_id = ? AND task_id = ? AND attempt = ?', [
		goal_id,
		task_id,
		request.attempt.str(),
	])!
	if receipt_rows.len != 1 {
		return error('goal task acceptance record could not be read after insert')
	}
	store.db.commit()!
	return GoalTaskAcceptanceReceipt{
		goal_id:          goal_id
		task_id:          task_id
		attempt:          request.attempt
		repository:       receipt_rows[0].val(0)
		base_sha:         receipt_rows[0].val(1)
		candidate_sha:    receipt_rows[0].val(2)
		decision:         receipt_rows[0].val(3)
		actor:            receipt_rows[0].val(4)
		integrity_checks: json2.decode[[]string](receipt_rows[0].val(5)) or { [] }
		created_at:       receipt_rows[0].val(6)
	}
}

fn parse_goal_task_acceptance_request(raw string) !GoalTaskAcceptanceRequest {
	if goal_task_verifier_envelope_has_duplicate_keys(raw) {
		return error('acceptance request contains duplicate JSON fields')
	}
	keys := json2.decode[map[string]json2.Any](raw) or {
		return error('expected an acceptance JSON object')
	}
	if keys.len != 3 || !keys.keys().all(it in ['attempt', 'candidate_sha', 'decision']) {
		return error('acceptance request must contain exactly attempt, candidate_sha, and decision')
	}
	fields := json2.decode[GoalTaskAcceptanceRequestJSON](raw) or {
		return error('acceptance fields must all be strings')
	}
	mut attempt_digits_only := fields.attempt.len > 0 && fields.attempt.len <= 9
	for digit in fields.attempt {
		if digit < `0` || digit > `9` {
			attempt_digits_only = false
		}
	}
	if !attempt_digits_only
		|| !valid_goal_sha(fields.candidate_sha)
		|| fields.decision != 'accept' {
		return error('acceptance request contains an invalid attempt, candidate SHA, or decision')
	}
	attempt := strconv.atoi(fields.attempt) or { return error('acceptance attempt is invalid') }
	if attempt <= 0 {
		return error('acceptance attempt is invalid')
	}
	return GoalTaskAcceptanceRequest{
		attempt:       attempt
		candidate_sha: fields.candidate_sha
		decision:      fields.decision
	}
}

@['/v1/goals/:id/tasks/:task_id/accept'; post]
pub fn (app &App) accept_verified_goal_task(mut ctx Context, id string,
	task_id string) veb.Result {
	if ctx.req.data.len == 0 || ctx.req.data.len > max_goal_task_acceptance_request_bytes {
		return json_request_error(mut ctx, 'Goal task acceptance request must be between 1 byte and 4 KiB')
	}
	request := parse_goal_task_acceptance_request(ctx.req.data) or {
		return json_request_error(mut ctx, err.msg())
	}
	mut store := app.store
	manifest := store.admitted_goal_manifest(id) or {
		return json_server_error(mut ctx, 'Unable to read goal')
	}
	if manifest.len == 0 {
		ctx.res.set_status(.not_found)
		return ctx.json(APIError{ error: 'Goal not found' })
	}
	goal := json2.decode[GoalAdmission](manifest) or {
		return json_server_error(mut ctx, 'Unable to decode stored goal')
	}
	if _ := goal_task_by_id(goal, task_id) {
	} else {
		ctx.res.set_status(.not_found)
		return ctx.json(APIError{ error: 'Goal task not found' })
	}
	receipt := store.accept_goal_task(id, task_id, request) or {
		if err.msg().starts_with('acceptance conflict:') {
			return json_conflict_error(mut ctx, err.msg().all_after('acceptance conflict: '))
		}
		return json_server_error(mut ctx, 'Unable to record goal task acceptance')
	}
	return ctx.json(receipt)
}
