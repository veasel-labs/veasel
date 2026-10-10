module main

import veb

@['/v1/sessions/:id/workspace/commands'; get]
pub fn (app &App) list_shell_commands(mut ctx Context, id string) veb.Result {
	_ := app.store.get_session(id) or {
		ctx.res.set_status(.not_found)
		return ctx.json(APIError{
			error: 'session not found'
		})
	}
	return ctx.json(app.store.shell_commands(id) or {
		return json_server_error(mut ctx, 'Unable to list shell command proposals')
	})
}

@['/v1/sessions/:id/workspace/commands/:command_id'; get]
pub fn (app &App) get_shell_command(mut ctx Context, id string, command_id string) veb.Result {
	_ := app.store.get_session(id) or {
		ctx.res.set_status(.not_found)
		return ctx.json(APIError{
			error: 'session not found'
		})
	}
	mut store := app.store
	proposal := store.review_shell_command(id, command_id) or {
		if err.msg() == 'shell command not found' {
			ctx.res.set_status(.not_found)
			return ctx.json(APIError{
				error: 'shell command proposal not found'
			})
		}
		return json_server_error(mut ctx, 'Unable to record shell command review')
	}
	return ctx.json(proposal)
}

@['/v1/sessions/:id/workspace/commands/:command_id/reject'; post]
pub fn (app &App) reject_shell_command(mut ctx Context, id string, command_id string) veb.Result {
	_ := app.store.get_session(id) or {
		ctx.res.set_status(.not_found)
		return ctx.json(APIError{
			error: 'session not found'
		})
	}
	mut store := app.store
	store.reject_shell_command(id, command_id) or {
		if err.msg() == 'shell command is not awaiting review' {
			return json_conflict_error(mut ctx, 'Shell command is missing or no longer awaiting approval')
		}
		return json_server_error(mut ctx, 'Unable to reject shell command proposal')
	}
	return ctx.json(WorkspaceEditActionResponse{
		id:     command_id
		status: 'rejected'
	})
}

@['/v1/sessions/:id/workspace/commands/:command_id/approve'; post]
pub fn (app &App) approve_shell_command(mut ctx Context, id string, command_id string) veb.Result {
	if !app.begin_shell_operation() {
		ctx.res.set_status(.service_unavailable)
		return ctx.json(APIError{
			error: 'Veasel Code is shutting down and is not accepting shell command approvals'
		})
	}
	defer {
		app.finish_shell_operation()
	}
	session := app.store.get_session(id) or {
		ctx.res.set_status(.not_found)
		return ctx.json(APIError{
			error: 'session not found'
		})
	}
	mut slots := app.shell_command_slots
	if !slots.try_wait() {
		ctx.res.set_status(.too_many_requests)
		ctx.res.header.add_custom('Retry-After', '1') or {}
		return ctx.json(APIError{
			error: 'Shell command execution capacity is full; retry after the active command finishes'
		})
	}
	defer {
		slots.post()
	}
	mut turn_lock := app.session_turn_lock(id)
	turn_lock.wait()
	defer {
		turn_lock.post()
	}
	mut store := app.store
	proposal := store.begin_shell_command(id, command_id) or {
		if err.msg().contains('reviewed and is awaiting approval')
			|| err.msg().contains('no longer awaiting approval') {
			return json_conflict_error(mut ctx, 'Inspect the exact command first; it must still be awaiting approval')
		}
		return json_server_error(mut ctx, 'Unable to persist shell command approval')
	}
	result := run_approved_shell_command(session.directory, proposal)
	store.finish_shell_command(id, command_id, result) or {
		eprintln('veasel: command ${command_id} finished but its outcome could not be persisted: ${err.msg()}')
		ctx.res.set_status(.internal_server_error)
		return ctx.json(APIError{
			error: 'Command finished, but its result is uncertain; inspect workspace state before continuing'
		})
	}
	return ctx.json(ShellCommandSummary{
		id:              proposal.id
		command:         proposal.command
		cwd:             proposal.cwd
		timeout_seconds: proposal.timeout_seconds
		status:          result.status
		exit_code:       result.exit_code
		output:          result.output
		created_at:      proposal.created_at
		updated_at:      proposal.updated_at
	})
}
