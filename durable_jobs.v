module main

import context as vcontext
import json2

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
		operation_id, mut turn_ctx, cancel := app.begin_turn_operation(operation.session_id,
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
		app.schedule_durable_session_operation(operation.id, turn_done, cancel, operation.session_id,
			session, input)
	}
}

fn (app &App) schedule_durable_session_operation(operation_id string, turn_done chan int,
	cancel vcontext.CancelFn, id string, session Session, input ChatMessageInput) {
	spawn fn (app &App, operation_id string, turn_done chan int, cancel vcontext.CancelFn, id string,
		session Session, input ChatMessageInput) {
		mut background := vcontext.background()
		mut turn_ctx, cancel_turn := vcontext.with_timeout(mut background, max_agent_turn_duration)
		worker_done := chan int{cap: 1}
		spawn fn (turn_done chan int, worker_done chan int, cancel_turn vcontext.CancelFn) {
			select {
				_ := <-turn_done {
					cancel_turn()
				}
				_ := <-worker_done {
				}
			}
		}(turn_done, worker_done, cancel_turn)
		defer {
			worker_done <- 0
			cancel_turn()
			app.finish_turn_operation(operation_id)
			cancel()
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
		_ = app.run_session_message(mut turn_ctx, id, session, input, operation_id) or {
			app.record_session_turn_failure(id, operation_id, err.msg(), input.content)
			return
		}
	}(app, operation_id, turn_done, cancel, id, session, input)
}
