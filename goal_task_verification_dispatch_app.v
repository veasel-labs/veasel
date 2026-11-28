module main

import crypto.sha256
import json2
import time

const goal_task_verifier_lease_seconds = 90
const goal_task_verifier_heartbeat_interval = 20 * time.second
const goal_task_verifier_poll_interval = 250 * time.millisecond

// resume_goal_task_verification_dispatches is called at startup and after a
// canonical worker commits `verifying`. The database candidate query is the
// recovery source; this in-memory key only prevents duplicate local watchers.
fn (app &App) resume_goal_task_verification_dispatches() {
	mut store := app.store
	candidates := store.goal_task_verification_dispatch_candidates() or {
		eprintln('veasel: unable to scan Goal tasks awaiting verification')
		return
	}
	for candidate in candidates {
		key := goal_task_verification_dispatch_key(candidate.goal_id, candidate.task_id,
			candidate.attempt)
		mut dispatch_mutex := app.goal_verifier_mutex
		dispatch_mutex.lock()
		mut dispatches := app.goal_verifier_dispatches
		if key in dispatches {
			dispatch_mutex.unlock()
			continue
		}
		mut registry := app.operation_registry
		mut registry_lock := registry.mutex
		registry_lock.lock()
		if registry.closing {
			registry_lock.unlock()
			dispatch_mutex.unlock()
			return
		}
		mut dispatch_workers := registry.provider_workers
		dispatch_workers.add(1)
		registry_lock.unlock()
		dispatches[key] = true
		dispatch_mutex.unlock()
		spawn fn (app &App, candidate GoalTaskVerifierDispatchCandidate, key string) {
			defer {
				mut registry := app.operation_registry
				mut workers := registry.provider_workers
				workers.done()
				app.release_goal_task_verifier_dispatch(key)
			}
			app.dispatch_goal_task_verifier(candidate)
		}(app, candidate, key)
	}
}

fn goal_task_verification_dispatch_key(goal_id string, task_id string, attempt int) string {
	return '${goal_id}/${task_id}/${attempt}'
}

fn (app &App) release_goal_task_verifier_dispatch(key string) {
	mut dispatch_mutex := app.goal_verifier_mutex
	dispatch_mutex.lock()
	mut dispatches := app.goal_verifier_dispatches
	dispatches.delete(key)
	dispatch_mutex.unlock()
}

fn (app &App) dispatch_goal_task_verifier(candidate GoalTaskVerifierDispatchCandidate) {
	mut store := app.store
	if app.turn_operations_are_closing() {
		return
	}
	parent_session := store.get_session(candidate.parent_session_id) or {
		_ = store.best_effort_mark_goal_task_verification_uncertain(candidate.goal_id, candidate.task_id,
			candidate.attempt, 'Reviewer dispatch could not load its parent session.')
		return
	}
	parent_operation := store.get_session_operation(candidate.parent_session_id,
		candidate.parent_operation_id) or {
		_ = store.best_effort_mark_goal_task_verification_uncertain(candidate.goal_id, candidate.task_id,
			candidate.attempt, 'Reviewer dispatch could not load its completed worker operation.')
		return
	}
	if parent_operation.status != 'completed' || parent_operation.outcome != 'completed' {
		if parent_operation.status != 'completed' || parent_operation.outcome != 'completed_with_denials' {
			return
		}
	}
	mut route := app.goal_task_verifier_route(candidate, parent_session.id, parent_operation) or {
		_ = store.best_effort_mark_goal_task_verification_uncertain(candidate.goal_id, candidate.task_id,
			candidate.attempt, 'No supported verifier provider/model route is available.')
		return
	}
	if provider_cli_by_id(route.provider) != none {
		route.permission_mode = 'ask'
	}
	validate_delegation_target(route) or {
		_ = store.best_effort_mark_goal_task_verification_uncertain(candidate.goal_id, candidate.task_id,
			candidate.attempt, 'The verifier provider/model route is unavailable.')
		return
	}
	if route.provider.trim_space().len == 0 || route.model.trim_space().len == 0 {
		_ = store.best_effort_mark_goal_task_verification_uncertain(candidate.goal_id, candidate.task_id,
			candidate.attempt, 'The verifier provider/model route is incomplete.')
		return
	}
	if store.active_subagent_run_count(candidate.parent_session_id) >= max_active_subagent_runs_per_parent {
		return
	}

	lease_lookup := store.current_goal_task_verification_lease(candidate.goal_id, candidate.task_id,
		candidate.attempt) or {
		_ = store.best_effort_mark_goal_task_verification_uncertain(candidate.goal_id, candidate.task_id,
			candidate.attempt, 'The durable verifier lease could not be read.')
		return
	}
	mut lease := GoalTaskVerificationLease{}
	if lease_lookup.found {
		current := lease_lookup.lease
		if !goal_task_verification_lease_is_active(current) {
			lease = store.claim_goal_task_verification_lease(candidate.goal_id, candidate.task_id,
				candidate.attempt, goal_task_verifier_lease_seconds) or {
				_ = store.expire_goal_task_verification_lease(candidate.goal_id, candidate.task_id,
					candidate.attempt, current.fencing_token, current.generation) or { false }
				return
			}
		} else {
			lease = current
		}
	} else {
		lease = store.claim_goal_task_verification_lease(candidate.goal_id, candidate.task_id,
			candidate.attempt, goal_task_verifier_lease_seconds) or {
			return
		}
	}

	binding := store.reserve_goal_task_verifier_binding(candidate.goal_id, candidate.task_id,
		candidate.attempt, lease.fencing_token, lease.generation) or {
		_ = store.best_effort_mark_goal_task_verification_uncertain(candidate.goal_id, candidate.task_id,
			candidate.attempt, 'The committed candidate could not be reserved for verification.')
		return
	}
	if binding.status == 'consumed' {
		_ = store.best_effort_mark_goal_task_verification_uncertain(candidate.goal_id, candidate.task_id,
			candidate.attempt, 'A consumed verifier binding has no durable receipt.')
		return
	}
	prompt := goal_task_verifier_review_prompt(binding, candidate.goal, candidate.task)
	if prompt.len > 8192 {
		_ = store.best_effort_mark_goal_task_verification_uncertain(candidate.goal_id, candidate.task_id,
			candidate.attempt, 'The trusted reviewer context exceeded its input limit.')
		return
	}
	request_id := goal_task_verifier_request_id(candidate.goal_id, candidate.task_id,
		candidate.attempt)
	prepared := app.prepare_subagent_task_with_policy(candidate.parent_session_id,
		candidate.parent_operation_id, request_id, 'reviewer', prompt, route.provider, route.model,
		execution_policy_turn_from_input('', false, false), AgentToolPolicy{}) or {
		if err.msg() == 'child agent concurrency limit reached' {
			return
		}
		_ = store.best_effort_mark_goal_task_verification_uncertain(candidate.goal_id, candidate.task_id,
			candidate.attempt, 'The trusted reviewer run could not be prepared.')
		return
	}
	if binding.status == 'reserved' {
		_ = store.bind_goal_task_verifier_run(binding.id, prepared.run.id,
			lease.fencing_token, lease.generation) or {
			_ = store.best_effort_mark_goal_task_verification_uncertain(candidate.goal_id, candidate.task_id,
				candidate.attempt, 'The trusted reviewer run could not be bound to its lease.')
			return
		}
	} else if binding.status != 'bound' || binding.reviewer_run_id != prepared.run.id {
		_ = store.best_effort_mark_goal_task_verification_uncertain(candidate.goal_id, candidate.task_id,
			candidate.attempt, 'The persisted reviewer run does not match its binding.')
		return
	}
	if app.turn_operations_are_closing() {
		_ = store.best_effort_mark_goal_task_verification_uncertain(candidate.goal_id, candidate.task_id,
			candidate.attempt, 'The server is shutting down before reviewer launch.')
		return
	}
	run := app.launch_prepared_subagent_task(prepared) or {
		current := store.get_subagent_run(prepared.run.id) or { SubagentRun{} }
		if current.id.len > 0 {
			app.wait_for_goal_task_verifier(candidate, current.id, lease)
		} else {
			_ = store.best_effort_mark_goal_task_verification_uncertain(candidate.goal_id, candidate.task_id,
				candidate.attempt, 'The bound reviewer run could not be started.')
		}
		return
	}
	app.wait_for_goal_task_verifier(candidate, run.id, lease)
}

fn (app &App) goal_task_verifier_route(candidate GoalTaskVerifierDispatchCandidate,
	parent_session_id string, parent_operation SessionOperation) !ModelConfig {
	if candidate.task.verifier_provider.trim_space().len > 0
		&& candidate.task.verifier_model.trim_space().len > 0 {
		return app.provider_model_config_for_target(candidate.task.verifier_provider.trim_space(),
			candidate.task.verifier_model.trim_space())
	}
	if parent_operation.provider.trim_space().len > 0 && parent_operation.model.trim_space().len > 0 {
		return app.provider_model_config_for_target(parent_operation.provider.trim_space(),
			parent_operation.model.trim_space())
	}
	return app.model_config_for_session(parent_session_id)
}

fn goal_task_verifier_request_id(goal_id string, task_id string, attempt int) string {
	digest := sha256.hexhash('${goal_id}\n${task_id}\n${attempt}')
	return 'goal-verifier-${digest[..40]}'
}

fn goal_task_verification_lease_is_active(lease GoalTaskVerificationLease) bool {
	hard := time.parse_rfc3339(lease.verification_deadline) or { return false }
	expires := time.parse_rfc3339(lease.lease_expires_at) or { return false }
	now := time.now()
	return now < hard && now < expires
}

fn (app &App) wait_for_goal_task_verifier(candidate GoalTaskVerifierDispatchCandidate,
	run_id string, initial_lease GoalTaskVerificationLease) {
	mut store := app.store
	mut lease := initial_lease
	for {
		run := store.get_subagent_run(run_id) or {
			_ = store.best_effort_mark_goal_task_verification_uncertain(candidate.goal_id, candidate.task_id,
				candidate.attempt, 'The persisted reviewer run could not be recovered.')
			return
		}
		if run.status == 'completed' {
			app.reconcile_goal_task_verifier_run(run_id)
			return
		}
		if run.status in ['failed', 'cancelled', 'uncertain'] {
			_ = store.best_effort_mark_goal_task_verification_uncertain(candidate.goal_id, candidate.task_id,
				candidate.attempt, 'The independent reviewer did not produce a valid receipt.')
			return
		}
		if app.turn_operations_are_closing() {
			return
		}
		now := time.now()
		hard := time.parse_rfc3339(lease.verification_deadline) or {
			_ = store.best_effort_mark_goal_task_verification_uncertain(candidate.goal_id, candidate.task_id,
				candidate.attempt, 'The verifier hard deadline is invalid.')
			return
		}
		expires := time.parse_rfc3339(lease.lease_expires_at) or {
			_ = store.best_effort_mark_goal_task_verification_uncertain(candidate.goal_id, candidate.task_id,
				candidate.attempt, 'The verifier lease expiry is invalid.')
			return
		}
		if now >= hard || now >= expires {
			_ = app.cancel_subagent_run(candidate.parent_session_id, run_id) or { SubagentRun{} }
			_ = store.expire_goal_task_verification_lease(candidate.goal_id, candidate.task_id,
				candidate.attempt, lease.fencing_token, lease.generation) or { false }
			return
		}
		if expires - now <= goal_task_verifier_heartbeat_interval {
			lease = store.renew_goal_task_verification_lease(candidate.goal_id,
				candidate.task_id, candidate.attempt, lease.fencing_token, lease.generation,
				goal_task_verifier_lease_seconds) or {
				current := store.current_goal_task_verification_lease(candidate.goal_id,
					candidate.task_id, candidate.attempt) or { GoalTaskVerificationLeaseLookup{} }
				if current.found {
					newer := current.lease
					if newer.fencing_token != lease.fencing_token
						&& goal_task_verification_lease_is_active(newer) {
						lease = newer
						time.sleep(goal_task_verifier_poll_interval)
						continue
					}
				}
				_ = app.cancel_subagent_run(candidate.parent_session_id, run_id) or { SubagentRun{} }
				_ = store.expire_goal_task_verification_lease(candidate.goal_id,
					candidate.task_id, candidate.attempt, lease.fencing_token,
					lease.generation) or { false }
				_ = store.best_effort_mark_goal_task_verification_uncertain(candidate.goal_id,
					candidate.task_id, candidate.attempt,
					'The reviewer lease could not be renewed safely.')
				return
			}
		}
		time.sleep(goal_task_verifier_poll_interval)
	}
}

fn (app &App) turn_operations_are_closing() bool {
	mut registry := app.operation_registry
	mut registry_mutex := registry.mutex
	registry_mutex.lock()
	closing := registry.closing
	registry_mutex.unlock()
	return closing
}

// reconcile_goal_task_verifier_run stores a receipt only for a bound, trusted
// reviewer run. Other built-in subagents follow their normal delivery path.
fn (app &App) reconcile_goal_task_verifier_run(run_id string) {
	mut store := app.store
	mut store_mutex := store.mu
	store_mutex.lock()
	bindings := store.db.exec_param_many("SELECT goal_id, task_id, attempt, id FROM goal_task_verifier_bindings WHERE reviewer_run_id = ? AND status = 'bound'", [
		run_id,
	]) or {
		store_mutex.unlock()
		return
	}
	store_mutex.unlock()
	if bindings.len != 1 {
		app.resume_goal_task_verification_dispatches()
		return
	}
	_ := store.record_goal_task_verification_receipt(bindings[0].val(3)) or {
		_ = store.best_effort_mark_goal_task_verification_uncertain(bindings[0].val(0),
			bindings[0].val(1), bindings[0].val(2).int(),
			'The reviewer result did not validate against the active candidate and lease.')
		return
	}
	app.resume_goal_task_verification_dispatches()
}

fn (mut store Store) mark_goal_task_verification_uncertain(goal_id string, task_id string,
	attempt int, reason string) !bool {
	store.mu.lock()
	defer { store.mu.unlock() }
	store.db.exec('BEGIN IMMEDIATE')!
	defer { store.db.rollback() or {} }
	rows := store.db.exec_param_many('SELECT a.status, a.session_id, a.session_operation_id, s.status FROM goal_task_attempts a JOIN goal_task_states s ON s.goal_id = a.goal_id AND s.task_id = a.task_id WHERE a.goal_id = ? AND a.task_id = ? AND a.attempt = ?', [
		goal_id,
		task_id,
		attempt.str(),
	])!
	if rows.len != 1 || rows[0].val(0) != 'verifying' || rows[0].val(3) != 'verifying' {
		store.db.commit()!
		return false
	}
	receipts := store.db.exec_param_many('SELECT COUNT(*) FROM goal_task_verification_receipts WHERE goal_id = ? AND task_id = ? AND attempt = ?', [
		goal_id,
		task_id,
		attempt.str(),
	])!
	if receipts.len != 1 || receipts[0].val(0).int() != 0 {
		store.db.commit()!
		return false
	}
	store.db.exec_param_many("UPDATE goal_task_attempts SET status = 'uncertain', ended_at = CURRENT_TIMESTAMP WHERE goal_id = ? AND task_id = ? AND attempt = ? AND status = 'verifying'", [
		goal_id,
		task_id,
		attempt.str(),
	])!
	store.db.exec_param_many("UPDATE goal_task_states SET status = 'uncertain', updated_at = CURRENT_TIMESTAMP WHERE goal_id = ? AND task_id = ? AND status = 'verifying'", [
		goal_id,
		task_id,
	])!
	store.db.exec_param_many("UPDATE goal_task_attempt_workspaces SET status = 'uncertain', updated_at = CURRENT_TIMESTAMP WHERE goal_id = ? AND task_id = ? AND attempt = ? AND status IN ('preparing', 'ready')", [
		goal_id,
		task_id,
		attempt.str(),
	])!
	store.db.exec_param_many('DELETE FROM goal_task_verification_leases WHERE goal_id = ? AND task_id = ? AND attempt = ?', [
		goal_id,
		task_id,
		attempt.str(),
	])!
	if rows[0].val(1).len > 0 {
		store.db.exec_param_many('INSERT INTO events (type, session_id, data) VALUES (?, ?, ?)', [
			'goal.task_verification_uncertain',
			rows[0].val(1),
			json2.encode[GoalTaskEventData](GoalTaskEventData{
				goal_id:      goal_id
				task_id:      task_id
				attempt:      attempt
				operation_id: rows[0].val(2)
				status:       'uncertain'
				outcome:      'uncertain'
				error:        truncate_utf8_bytes(reason, 512)
			}),
		])!
	}
	store.db.commit()!
	return true
}

fn (mut store Store) best_effort_mark_goal_task_verification_uncertain(goal_id string,
	task_id string, attempt int, reason string) bool {
	return store.mark_goal_task_verification_uncertain(goal_id, task_id, attempt, reason) or {
		false
	}
}

fn (mut store Store) active_subagent_run_count(parent_session_id string) int {
	store.mu.lock()
	defer { store.mu.unlock() }
	rows := store.db.exec_param_many("SELECT COUNT(*) FROM subagent_runs WHERE parent_session_id = ? AND status IN ('queued', 'running')",
		[parent_session_id]) or { return max_active_subagent_runs_per_parent }
	if rows.len != 1 { return max_active_subagent_runs_per_parent }
	return rows[0].val(0).int()
}
