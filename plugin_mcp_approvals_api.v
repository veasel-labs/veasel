module main

import veb

@['/v1/sessions/:id/mcp-tool-calls'; get]
pub fn (app &App) get_session_plugin_mcp_tool_calls(mut ctx Context, id string) veb.Result {
	_ := app.store.get_session(id) or {
		ctx.res.set_status(.not_found)
		return ctx.json(APIError{
			error: 'session not found'
		})
	}
	calls := app.store.plugin_mcp_tool_calls(id) or {
		return json_server_error(mut ctx, 'Unable to read MCP tool call history')
	}
	return ctx.json(calls)
}

@['/v1/sessions/:id/mcp-tool-calls/:call_id'; get]
pub fn (app &App) get_session_plugin_mcp_tool_call(mut ctx Context, id string,
	call_id string) veb.Result {
	_ := app.store.get_session(id) or {
		ctx.res.set_status(.not_found)
		return ctx.json(APIError{
			error: 'session not found'
		})
	}
	call := app.store.review_plugin_mcp_tool_call(id, call_id) or {
		if err.msg() == 'MCP tool call not found' {
			ctx.res.set_status(.not_found)
			return ctx.json(APIError{
				error: err.msg()
			})
		}
		return json_server_error(mut ctx, 'Unable to inspect MCP tool call')
	}
	return ctx.json(call)
}

@['/v1/sessions/:id/mcp-tool-calls/:call_id/approve'; post]
pub fn (app &App) approve_session_plugin_mcp_tool_call(mut ctx Context, id string,
	call_id string) veb.Result {
	return app.transition_session_plugin_mcp_tool_call(mut ctx, id, call_id, true)
}

@['/v1/sessions/:id/mcp-tool-calls/:call_id/reject'; post]
pub fn (app &App) reject_session_plugin_mcp_tool_call(mut ctx Context, id string,
	call_id string) veb.Result {
	return app.transition_session_plugin_mcp_tool_call(mut ctx, id, call_id, false)
}

fn (app &App) transition_session_plugin_mcp_tool_call(mut ctx Context, id string,
	call_id string, approve bool) veb.Result {
	_ := app.store.get_session(id) or {
		ctx.res.set_status(.not_found)
		return ctx.json(APIError{
			error: 'session not found'
		})
	}
	call := app.store.get_plugin_mcp_tool_call(id, call_id) or {
		if err.msg() == 'MCP tool call not found' {
			ctx.res.set_status(.not_found)
			return ctx.json(APIError{
				error: err.msg()
			})
		}
		return json_server_error(mut ctx, 'Unable to read MCP tool call state')
	}
	if call.status != 'pending' || approve && call.reviewed_at.len == 0 {
		return json_conflict_error(mut ctx, if approve {
			'MCP tool call must be inspected before approval'
		} else {
			'MCP tool call is no longer awaiting review'
		})
	}
	if approve {
		app.store.approve_plugin_mcp_tool_call(id, call_id) or {
			return json_conflict_error(mut ctx, 'MCP tool call is no longer awaiting approval')
		}
	} else {
		app.store.reject_plugin_mcp_tool_call(id, call_id) or {
			return json_conflict_error(mut ctx, 'MCP tool call is no longer awaiting review')
		}
	}
	return ctx.json(app.store.get_plugin_mcp_tool_call(id, call_id) or {
		return json_server_error(mut ctx, 'Unable to read updated MCP tool call state')
	})
}
