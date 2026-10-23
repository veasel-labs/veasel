module main

import context as vcontext
import json2
import time

// Durable Prefer: respond-async turns persist as queued with request_json before a
// worker claims them. Queued jobs resume after restart. Running/cancelling rows
// remain fail-closed as uncertain because provider or tool effects may already
// have started without a durable result.

fn (app &App) resume_durable_queued_operations() {
	mut store := app.store
	queued := store.list_queued_session_operations() or {
		eprintln('veasel: unable to list queued session operations for resume (${err.msg()})')
		return
	}
	for operation in queued {
		session := store.get_session(operation.session_id) or {
			eprintln('veasel: rejecting queued operation ${operation.id}; session missing')
			store.reject_queued_session_operation(operation.session_id, operation.id,
				'Queued turn session is missing and will not be claimed.') or {
				eprintln('veasel: unable to reject orphaned queued operation ${operation.id}')
				''
			}
			continue
		}
		_ := canonical_workspace_root(session.directory) or {
			eprintln('veasel: rejecting queued operation ${operation.id}; workspace missing')
			store.reject_queued_session_operation(operation.session_id, operation.id,
				'Queued turn session workspace is missing and will not be claimed.') or {
				eprintln('veasel: unable to reject queued operation with missing workspace ${operation.id}')
				''
			}
			continue
		}
		request_json := store.session_operation_request_json(operation.session_id, operation.id) or {
			eprintln('veasel: rejecting queued operation ${operation.id}; request missing')
			store.reject_queued_session_operation(operation.session_id, operation.id,
				'Queued turn request payload is missing and will not be claimed.') or {
				eprintln('veasel: unable to reject queued operation without request ${operation.id}')
				''
			}
			continue
		}
		if request_json.trim_space().len == 0 {
			eprintln('veasel: rejecting queued operation ${operation.id}; request empty')
			store.reject_queued_session_operation(operation.session_id, operation.id,
				'Queued turn request payload is missing and will not be claimed.') or {
				eprintln('veasel: unable to reject queued operation without request ${operation.id}')
				''
			}
			continue
		}
		if request_json.contains('\0') {
			eprintln('veasel: rejecting queued operation ${operation.id}; request contains NUL')
			store.reject_queued_session_operation(operation.session_id, operation.id,
				'Queued turn request was invalid and will not be claimed.') or {
				eprintln('veasel: unable to reject queued operation with NUL request ${operation.id}')
				''
			}
			continue
		}
		input := json2.decode[ChatMessageInput](request_json) or {
			eprintln('veasel: skipping queued operation ${operation.id}; request invalid')
			store.reject_queued_session_operation(operation.session_id, operation.id,
				'Queued turn request was invalid and will not be claimed.') or {
				eprintln('veasel: unable to reject invalid queued operation ${operation.id}')
				''
			}
			continue
		}
		validate_messages([
			ChatMessage{
				role:    'user'
				content: input.content
			},
		]) or {
			eprintln('veasel: rejecting queued operation ${operation.id}; request content invalid')
			store.reject_queued_session_operation(operation.session_id, operation.id,
				'Queued turn request content was invalid and will not be claimed.') or {
				eprintln('veasel: unable to reject queued operation with invalid content ${operation.id}')
				''
			}
			continue
		}
		policy := execution_policy_turn_from_input(input.execution_policy, input.autonomous,
			input.non_interactive)
		if err_msg := app.execution_policy_forbidden_reason(policy) {
			eprintln('veasel: rejecting queued operation ${operation.id}; ${err_msg}')
			store.reject_queued_session_operation(operation.session_id, operation.id,
				'Queued turn cannot start because its execution policy is disabled on this server.') or {
				eprintln('veasel: unable to reject queued policy-gated operation ${operation.id}')
				''
			}
			continue
		}
		if app.configured_model() == none {
			eprintln('veasel: rejecting queued operation ${operation.id}; model not configured')
			store.reject_queued_session_operation(operation.session_id, operation.id,
				'Queued turn cannot start because a model is not configured.') or {
				eprintln('veasel: unable to reject queued operation without a model ${operation.id}')
				''
			}
			continue
		}
		operation_id, mut turn_ctx, cancel := app.begin_queued_turn_operation(operation.session_id,
			operation.id) or {
			eprintln('veasel: unable to resume queued operation ${operation.id} (${err.msg()})')
			continue
		}
		if operation_id != operation.id {
			app.finish_turn_operation(operation_id)
			cancel()
			continue
		}
		turn_done := turn_ctx.done()
		app.schedule_durable_session_operation(operation.id, cancel, turn_done, operation.session_id,
			session, input)
	}
}

fn (app &App) schedule_durable_session_operation(operation_id string, cancel vcontext.CancelFn,
	turn_done chan int, id string, session Session, input ChatMessageInput) {
	spawn fn (app &App, operation_id string, cancel vcontext.CancelFn, turn_done chan int, id string,
		session Session, input ChatMessageInput) {
		defer {
			app.finish_turn_operation(operation_id)
			cancel()
		}
		// Keep the durable row queued while it waits for this session's active turn.
		// A restart can then safely resume it because no provider or tool effect began.
		mut turn_lock := app.session_turn_lock(id)
		app.acquire_queued_session_turn(turn_done, id, operation_id) or {
			if err.msg() == 'cancelled' {
				// Cancellation can arrive after the request is registered but before
				// its durable row is inserted. Persist the terminal state here so
				// that early cancellation cannot strand a queued row indefinitely.
				mut store := app.store
				_ = store.cancel_session_operation(id, operation_id) or {
					eprintln('veasel: unable to persist queued cancellation (${err.msg()})')
					''
				}
			}
			return
		}
		defer {
			turn_lock.post()
		}
		mut store := app.store
		_ = store.claim_session_operation(id, operation_id) or {
			// Cancelled while queued, already claimed, or classified after crash.
			if err.msg().starts_with('session operation is') {
				return
			}
			eprintln('veasel: unable to claim queued session operation (${err.msg()})')
			app.record_session_turn_failure(id, operation_id, 'unable to claim queued session operation',
				input.content)
			return
		}
		// Start the time limit from a fresh background context after the queued
		// turn owns the session. Forward request cancellation through the channel
		// captured before the Context interface crossed this worker boundary.
		mut deadline_parent := vcontext.background()
		request_deadline := time.now().add(max_agent_turn_duration)
		mut bounded_turn_ctx, cancel_bounded := vcontext.with_deadline(mut deadline_parent,
			request_deadline)
		cancel_watch := chan int{cap: 1}
		watch_done := chan int{cap: 1}
		spawn fn (turn_done chan int, stop chan int, watch_done chan int, cancel_bounded vcontext.CancelFn) {
			select {
				_ := <-turn_done {
					cancel_bounded()
				}
				_ := <-stop {
				}
			}
			watch_done <- 0
			watch_done.close()
		}(turn_done, cancel_watch, watch_done, cancel_bounded)
		defer {
			cancel_watch <- 0
			_ = <-watch_done
			cancel_watch.close()
			cancel_bounded()
		}
		_ = app.run_session_message_locked(mut bounded_turn_ctx, id, session, input, operation_id,
			request_deadline) or {
			app.record_session_turn_failure(id, operation_id, err.msg(), input.content)
			return
		}
	}(app, operation_id, cancel, turn_done, id, session, input)
}
