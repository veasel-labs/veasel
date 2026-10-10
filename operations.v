module main

import context as vcontext
import sync
import time
import uuid

@[heap]
struct TurnOperationRegistry {
mut:
	mutex            &sync.Mutex
	operations       map[string]ActiveTurnOperation
	provider_workers &sync.WaitGroup
	closing          bool
}

struct ActiveTurnOperation {
	session_id string
	cancel     vcontext.CancelFn @[required]
}

fn (app &App) begin_turn_operation(session_id string, requested_id string) !(string, vcontext.Context, vcontext.CancelFn) {
	operation_id := if requested_id.trim_space().len == 0 {
		uuid.new_v4().str()
	} else {
		parsed := uuid.parse(requested_id) or { return error('invalid_operation_id') }
		if parsed == uuid.nil_uuid {
			return error('invalid_operation_id')
		}
		parsed.str()
	}
	mut background := vcontext.background()
	turn_ctx, cancel := vcontext.with_timeout(mut background, max_agent_turn_duration)
	mut registry := app.operation_registry
	mut registry_lock := registry.mutex
	registry_lock.lock()
	if registry.closing {
		registry_lock.unlock()
		cancel()
		return error('app_shutting_down')
	}
	if operation_id in registry.operations {
		registry_lock.unlock()
		cancel()
		return error('operation_id_in_use')
	}
	if registry.operations.len >= max_active_turn_operations {
		registry_lock.unlock()
		cancel()
		return error('operations_busy')
	}
	registry.operations[operation_id] = ActiveTurnOperation{
		session_id: session_id
		cancel:     cancel
	}
	registry_lock.unlock()
	return operation_id, turn_ctx, cancel
}

fn (app &App) finish_turn_operation(operation_id string) {
	mut registry := app.operation_registry
	mut registry_lock := registry.mutex
	registry_lock.lock()
	registry.operations.delete(operation_id)
	registry_lock.unlock()
}

fn (app &App) begin_provider_worker() ?&sync.WaitGroup {
	mut registry := app.operation_registry
	mut registry_lock := registry.mutex
	registry_lock.lock()
	if registry.closing {
		registry_lock.unlock()
		return none
	}
	mut workers := registry.provider_workers
	workers.add(1)
	registry_lock.unlock()
	return registry.provider_workers
}

fn (app &App) cancel_turn_operation(session_id string, operation_id string) bool {
	parsed_id := uuid.parse(operation_id) or { return false }
	canonical_id := parsed_id.str()
	mut registry := app.operation_registry
	mut registry_lock := registry.mutex
	registry_lock.lock()
	operation := registry.operations[canonical_id] or {
		registry_lock.unlock()
		return false
	}
	if session_id.len > 0 && operation.session_id != session_id {
		registry_lock.unlock()
		return false
	}
	registry_lock.unlock()
	operation.cancel()
	return true
}

fn (mut app App) cancel_all_turn_operations() {
	mut registry := app.operation_registry
	mut registry_lock := registry.mutex
	registry_lock.lock()
	registry.closing = true
	operations := registry.operations.values()
	registry_lock.unlock()
	for operation in operations {
		operation.cancel()
	}
}

fn (app &App) wait_for_turn_operations() {
	for {
		mut registry := app.operation_registry
		mut registry_lock := registry.mutex
		registry_lock.lock()
		active := registry.operations.len
		registry_lock.unlock()
		if active == 0 {
			return
		}
		time.sleep(10 * time.millisecond)
	}
}

fn (app &App) acquire_session_turn(mut turn_ctx vcontext.Context, session_id string) ! {
	mut slot := app.session_turn_lock(session_id)
	for {
		if context_error := turn_context_error(mut turn_ctx) {
			return error(context_error)
		}
		if slot.timed_wait(10 * time.millisecond) {
			if context_error := turn_context_error(mut turn_ctx) {
				slot.post()
				return error(context_error)
			}
			return
		}
	}
}

fn turn_context_error(mut ctx vcontext.Context) ?string {
	err := ctx.err()
	if err !is none {
		return if err.msg().contains('deadline') { 'deadline_exceeded' } else { 'cancelled' }
	}
	return none
}

fn wait_for_provider_turn(mut turn_ctx vcontext.Context,
	result_chan chan ProviderTurnResult) !CompletionOutput {
	done := turn_ctx.done()
	select {
		result := <-result_chan {
			if context_error := turn_context_error(mut turn_ctx) {
				return error(context_error)
			}
			if result.error.len > 0 {
				return error(result.error)
			}
			return result.output
		}
		_ := <-done {
			if context_error := turn_context_error(mut turn_ctx) {
				return error(context_error)
			}
			return error('cancelled')
		}
	}
	return error('cancelled')
}

fn validate_operation_id(id string) bool {
	if id.trim_space().len == 0 {
		return true
	}
	parsed := uuid.parse(id) or { return false }
	return parsed != uuid.nil_uuid
}

fn canonical_operation_id(id string) !string {
	parsed := uuid.parse(id)!
	if parsed == uuid.nil_uuid {
		return error('invalid_operation_id')
	}
	return parsed.str()
}
