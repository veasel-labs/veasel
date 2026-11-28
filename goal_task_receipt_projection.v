module main

import json2
import veb

// GoalTaskReceiptProjection is a versioned, safe API view of the evidence
// Veasel recorded for one task attempt. It deliberately omits local paths.
pub struct GoalTaskReceiptProjection {
pub:
	schema_version       int = 1
	goal_id              string
	task_id              string
	attempt              int
	verification_receipt ?GoalTaskVerificationEvidence @[omitempty]
	acceptance_receipt   ?GoalTaskAcceptanceEvidence   @[omitempty]
}

pub struct GoalTaskVerificationEvidence {
pub:
	repository        string
	base_sha          string
	candidate_sha     string
	verifier_id       string
	verifier_version  string
	reviewer_provider string
	reviewer_model    string
	reviewer_run_id   string
	lease_generation  int
	verdict           string
	evidence          string
	changed_paths     []string
	created_at        string
}

pub struct GoalTaskAcceptanceEvidence {
pub:
	repository       string
	base_sha         string
	candidate_sha    string
	decision         string
	actor            string
	integrity_checks []string
	created_at       string
}

fn project_goal_task_receipts(verification ?GoalTaskVerificationReceipt,
	acceptance ?GoalTaskAcceptanceReceipt, goal_id string, task_id string,
	attempt int) !GoalTaskReceiptProjection {
	if verification_receipt := verification {
		if acceptance_receipt := acceptance {
			if verification_receipt.repository != acceptance_receipt.repository
				|| verification_receipt.base_sha != acceptance_receipt.base_sha
				|| verification_receipt.candidate_sha != acceptance_receipt.candidate_sha {
				return error('stored acceptance does not match verification evidence')
			}
		}
	}
	mut projected_verification := ?GoalTaskVerificationEvidence(none)
	if receipt := verification {
		projected_verification = GoalTaskVerificationEvidence{
			repository:        receipt.repository
			base_sha:          receipt.base_sha
			candidate_sha:     receipt.candidate_sha
			verifier_id:       receipt.verifier_id
			verifier_version:  receipt.verifier_version
			reviewer_provider: receipt.reviewer_provider
			reviewer_model:    receipt.reviewer_model
			reviewer_run_id:   receipt.reviewer_run_id
			lease_generation:  receipt.lease_generation
			verdict:           receipt.verdict
			evidence:          receipt.evidence
			changed_paths:     receipt.changed_paths.clone()
			created_at:        receipt.created_at
		}
	}
	mut projected_acceptance := ?GoalTaskAcceptanceEvidence(none)
	if receipt := acceptance {
		projected_acceptance = GoalTaskAcceptanceEvidence{
			repository:       receipt.repository
			base_sha:         receipt.base_sha
			candidate_sha:    receipt.candidate_sha
			decision:         receipt.decision
			actor:            receipt.actor
			integrity_checks: receipt.integrity_checks.clone()
			created_at:       receipt.created_at
		}
	}
	return GoalTaskReceiptProjection{
		goal_id:              goal_id
		task_id:              task_id
		attempt:              attempt
		verification_receipt: projected_verification
		acceptance_receipt:   projected_acceptance
	}
}

fn (mut store Store) goal_task_receipt_projection(goal_id string, task_id string,
	attempt int) !GoalTaskReceiptProjection {
	store.mu.lock()
	defer { store.mu.unlock() }
	attempt_rows := store.db.exec_param_many('SELECT 1 FROM goal_task_attempts WHERE goal_id = ? AND task_id = ? AND attempt = ?', [
		goal_id,
		task_id,
		attempt.str(),
	])!
	if attempt_rows.len != 1 {
		return error('goal task attempt not found')
	}
	mut verification := ?GoalTaskVerificationReceipt(none)
	verification_rows := store.db.exec_param_many('SELECT 1 FROM goal_task_verification_receipts WHERE goal_id = ? AND task_id = ? AND attempt = ?', [
		goal_id,
		task_id,
		attempt.str(),
	])!
	if verification_rows.len == 1 {
		verification = store.get_goal_task_verification_receipt_unlocked(goal_id, task_id,
			attempt)!
	}
	mut acceptance := ?GoalTaskAcceptanceReceipt(none)
	acceptance_rows := store.db.exec_param_many('SELECT 1 FROM goal_task_acceptances WHERE goal_id = ? AND task_id = ? AND attempt = ?', [
		goal_id,
		task_id,
		attempt.str(),
	])!
	if acceptance_rows.len == 1 {
		acceptance = store.goal_task_acceptance_receipt_unlocked(goal_id, task_id,
			attempt)!
	}
	return project_goal_task_receipts(verification, acceptance, goal_id, task_id, attempt)
}

fn (mut store Store) goal_task_acceptance_receipt_unlocked(goal_id string, task_id string,
	attempt int) !GoalTaskAcceptanceReceipt {
	rows := store.db.exec_param_many('SELECT repository, base_sha, candidate_sha, decision, actor, checks_json, created_at FROM goal_task_acceptances WHERE goal_id = ? AND task_id = ? AND attempt = ?', [
		goal_id,
		task_id,
		attempt.str(),
	])!
	if rows.len != 1 {
		return error('goal task acceptance receipt not found')
	}
	return GoalTaskAcceptanceReceipt{
		goal_id:          goal_id
		task_id:          task_id
		attempt:          attempt
		repository:       rows[0].val(0)
		base_sha:         rows[0].val(1)
		candidate_sha:    rows[0].val(2)
		decision:         rows[0].val(3)
		actor:            rows[0].val(4)
		integrity_checks: json2.decode[[]string](rows[0].val(5)) or {
			return error('stored acceptance checks are invalid')
		}
		created_at:       rows[0].val(6)
	}
}

fn parse_goal_task_attempt_path(attempt string) !int {
	if attempt.len == 0 || attempt.len > 9 {
		return error('invalid attempt')
	}
	number := attempt.int()
	if number <= 0 || number.str() != attempt {
		return error('invalid attempt')
	}
	return number
}

@['/v1/goals/:id/tasks/:task_id/attempts/:attempt/receipts'; get]
pub fn (app &App) get_goal_task_receipt_projection(mut ctx Context, id string,
	task_id string, attempt string) veb.Result {
	attempt_number := parse_goal_task_attempt_path(attempt) or {
		return json_request_error(mut ctx, 'Goal task attempt must be a positive integer')
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
	projection := store.goal_task_receipt_projection(id, task_id, attempt_number) or {
		if err.msg() == 'goal task attempt not found' {
			ctx.res.set_status(.not_found)
			return ctx.json(APIError{ error: 'Goal task attempt not found' })
		}
		return json_server_error(mut ctx, 'Unable to read goal task evidence')
	}
	return ctx.json(projection)
}
