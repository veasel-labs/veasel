module main

import json2
import os

// GoalTaskVerifierDispatchCandidate is a read-only selection result for the
// server-owned reviewer sweep. It carries the admitted Goal/Task and the exact
// parent operation identity; selection never claims a lease or starts a run.
struct GoalTaskVerifierDispatchCandidate {
pub:
	goal_id             string
	task_id             string
	attempt             int
	parent_session_id   string
	parent_operation_id string
	goal                GoalAdmission
	task                GoalTask
}

// Return current attempts ready for reviewer dispatch. Candidate identity is
// derived from the admitted manifest plus the completed worker and ready
// workspace rows. Dispatch rechecks and fences this snapshot transactionally.
fn (mut store Store) goal_task_verification_dispatch_candidates() ![]GoalTaskVerifierDispatchCandidate {
	store.mu.lock()
	defer { store.mu.unlock() }
	store.db.begin()!
	defer { store.db.rollback() or {} }
	rows := store.db.exec("SELECT a.goal_id, a.task_id, a.attempt, a.session_id, a.session_operation_id, g.manifest, w.repository_root, w.worktree_path, w.base_sha FROM goal_task_attempts a JOIN goal_task_states s ON s.goal_id = a.goal_id AND s.task_id = a.task_id JOIN goal_admissions g ON g.id = a.goal_id JOIN goal_task_attempt_workspaces w ON w.goal_id = a.goal_id AND w.task_id = a.task_id AND w.attempt = a.attempt JOIN session_operations o ON o.session_id = a.session_id AND o.id = a.session_operation_id JOIN sessions parent ON parent.id = a.session_id WHERE s.status = 'verifying' AND s.attempt_count = a.attempt AND a.attempt = (SELECT MAX(current.attempt) FROM goal_task_attempts current WHERE current.goal_id = a.goal_id AND current.task_id = a.task_id) AND a.status = 'verifying' AND a.session_id != '' AND a.session_operation_id != '' AND o.status = 'completed' AND o.outcome IN ('completed', 'completed_with_denials') AND w.status = 'ready' AND w.worktree_path != '' AND NOT EXISTS (SELECT 1 FROM goal_task_verification_receipts r WHERE r.goal_id = a.goal_id AND r.task_id = a.task_id AND r.attempt = a.attempt) ORDER BY a.goal_id, a.task_id")!
	mut candidates := []GoalTaskVerifierDispatchCandidate{cap: rows.len}
	for row in rows {
		goal_id := row.val(0)
		task_id := row.val(1)
		attempt := row.val(2).int()
		goal := json2.decode[GoalAdmission](row.val(5)) or { continue }
		if goal.id != goal_id {
			continue
		}
		validate_goal_admission(goal) or { continue }
		task := goal_task_by_id(goal, task_id) or { continue }
		mut admitted_root := ''
		for repository in goal.authorized_repositories {
			if task.repository.to_lower() == '${repository.owner}/${repository.name}'.to_lower() {
				admitted_root = repository.path
				break
			}
		}
		root := row.val(6)
		worktree := row.val(7)
		if admitted_root.len == 0 || root != admitted_root || row.val(8) != task.base_sha
			|| !os.is_abs_path(root) || !os.is_abs_path(worktree) || os.is_link(root)
			|| os.is_link(worktree) || !os.is_dir(root) || !os.is_dir(worktree)
			|| os.real_path(root) != root || os.real_path(worktree) != worktree
			|| goal_task_path_is_within(root, worktree) || task.verifier.trim_space().len == 0 {
			continue
		}
		candidates << GoalTaskVerifierDispatchCandidate{
			goal_id:             goal_id
			task_id:             task_id
			attempt:             attempt
			parent_session_id:   row.val(3)
			parent_operation_id: row.val(4)
			goal:                goal
			task:                task
		}
	}
	return candidates
}

struct BoundGoalTaskVerifier {
	id      string
	goal_id string
	task_id string
	attempt int
}

// Return bound verifier rows for a completed reviewer run under store.mu.
fn (mut store Store) list_bound_goal_task_verifiers(run_id string) ![]BoundGoalTaskVerifier {
	store.mu.lock()
	defer { store.mu.unlock() }
	rows := store.db.exec_param_many("SELECT goal_id, task_id, attempt, id FROM goal_task_verifier_bindings WHERE reviewer_run_id = ? AND status = 'bound'", [
		run_id,
	])!
	mut bindings := []BoundGoalTaskVerifier{cap: rows.len}
	for row in rows {
		bindings << BoundGoalTaskVerifier{
			goal_id: row.val(0)
			task_id: row.val(1)
			attempt: row.val(2).int()
			id:      row.val(3)
		}
	}
	return bindings
}
