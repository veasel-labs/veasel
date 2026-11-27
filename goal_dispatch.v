module main

import json2
import veb

// GoalTaskStartRequest is intentionally explicit. Starting a task is a
// mutating, authenticated action; the dispatcher never invents a prompt or
// executes a shell command on behalf of a manifest.
struct GoalTaskStartRequest {
pub:
	title           string
	prompt          string
	preferred_model string
	permission_mode string = 'ask'
}

struct GoalTaskDispatchResponse {
pub:
	goal_id          string
	task_id          string
	attempt          int
	session_id       string
	operation_id     string
	worktree_path    string
	base_sha         string
	operation_status string
}

// start_goal_task performs one local, draft-mode dispatch. The claim is made
// before the worktree exists, but is fenced; the session is created only after
// the exact-base worktree has been verified. Any failure after the claim is
// classified uncertain and cannot be replayed automatically.
@['/v1/goals/:id/tasks/:task_id/start'; post]
pub fn (app &App) start_goal_task(mut ctx Context, id string, task_id string) veb.Result {
	if ctx.req.data.len > 128 * 1024 {
		return json_request_error(mut ctx, 'Goal task start request exceeds 128 KiB')
	}
	request := json2.decode[GoalTaskStartRequest](ctx.req.data) or {
		return json_request_error(mut ctx, 'Expected JSON with title and prompt')
	}
	if request.prompt.trim_space().len == 0 || request.prompt.len > chat_input_byte_limit() {
		return json_request_error(mut ctx, 'Goal task prompt must be non-empty and within the chat input limit')
	}
	manifest := app.store.admitted_goal_manifest(id) or {
		return json_server_error(mut ctx, 'Unable to read goal')
	}
	if manifest == '' {
		ctx.res.set_status(.not_found)
		return ctx.json(APIError{ error: 'Goal not found' })
	}
	goal := json2.decode[GoalAdmission](manifest) or {
		return json_server_error(mut ctx, 'Unable to decode stored goal')
	}
	mut task := GoalTask{}
	mut found := false
	for candidate in goal.tasks {
		if candidate.id == task_id {
			task = candidate
			found = true
			break
		}
	}
	if !found {
		ctx.res.set_status(.not_found)
		return ctx.json(APIError{ error: 'Goal task not found' })
	}
	checkouts := verify_goal_checkouts(goal) or {
		return json_conflict_error(mut ctx, 'Goal checkout preflight failed: ${err.msg()}')
	}
	checkout := checkouts[task.repository.to_lower()] or {
		return json_conflict_error(mut ctx, 'Goal task repository was not verified')
	}
	mut store := app.store
	title := if request.title.trim_space().len == 0 {
		task.title
	} else {
		request.title.trim_space()
	}
	if !valid_session_title(title) {
		return json_request_error(mut ctx, 'Task session title is invalid')
	}
	provider := task.runner.trim_space()
	validated_prefs := app.validate_session_create_preferences(SessionInput{
		title:              title
		directory:          checkout.path
		preferred_provider: provider
		preferred_model:    request.preferred_model.trim_space()
		permission_mode:    request.permission_mode.trim_space()
	}) or {
		return json_request_error(mut ctx, err.msg())
	}
	claim := store.claim_goal_task_for_dispatch(id, task_id) or {
		if err.msg().contains('dependencies') || err.msg().contains('claimable') || err.msg().contains('budget') {
			return json_conflict_error(mut ctx, err.msg())
		}
		return json_server_error(mut ctx, 'Unable to claim goal task')
	}
	mut uncertain := true
	defer {
		if uncertain {
			store.complete_linked_goal_task_attempt(id, task_id, claim.state.attempt_count,
				claim.fencing_token, .uncertain) or {}
		}
	}
	worktree := store.prepare_goal_task_attempt_worktree(id, task_id, claim) or {
		return json_conflict_error(mut ctx, 'Goal task worktree preparation failed: ${err.msg()}')
	}
	prefs := app.validate_session_create_preferences(SessionInput{
		title:              validated_prefs.title
		directory:          worktree.path
		preferred_provider: validated_prefs.preferred_provider
		preferred_model:    validated_prefs.preferred_model
		permission_mode:    validated_prefs.permission_mode
		confirm_bypass:     validated_prefs.confirm_bypass
	}) or {
		return json_server_error(mut ctx, 'Unable to validate task worktree session preferences')
	}
	session := store.create_session(prefs) or {
		return json_server_error(mut ctx, 'Unable to create task session')
	}
	request_json := json2.encode[ChatMessageInput](ChatMessageInput{ content: request.prompt })
	operation_id := store.attach_goal_task_attempt_session(id, task_id, claim.state.attempt_count,
		claim.fencing_token, session.id, request_json) or {
		return json_server_error(mut ctx, 'Unable to link task session operation')
	}
	uncertain = false
	// Reuse the canonical durable session worker. It validates the selected
	// native runner and remains recoverable on backend restart.
	app.resume_durable_queued_operations()
	ctx.res.set_status(.accepted)
	return ctx.json(GoalTaskDispatchResponse{
		goal_id:          id
		task_id:          task_id
		attempt:          claim.state.attempt_count
		session_id:       session.id
		operation_id:     operation_id
		worktree_path:    worktree.path
		base_sha:         worktree.base_sha
		operation_status: 'queued'
	})
}
