module main

import veb
import json2

struct Health {
pub:
	healthy bool
	version string
}

struct Capabilities {
pub:
	api_version string
	features    []string
}

@['/v1/health'; get]
pub fn (app &App) health(mut ctx Context) veb.Result {
	return ctx.json(Health{
		healthy: true
		version: product_version
	})
}

@['/v1/capabilities'; get]
pub fn (app &App) capabilities(mut ctx Context) veb.Result {
	mut features := ['sessions.create', 'sessions.list', 'sessions.get', 'events.sse', 'events.replay',
		'plugins.catalog', 'sessions.skills', 'sessions.mcp_servers', 'workspace.files',
		'workspace.read', 'workspace.search', 'workspace.edits.review', 'workspace.edits.approve',
		'workspace.edits.reject', 'workspace.commands.propose', 'workspace.commands.review',
		'workspace.commands.approve', 'workspace.commands.reject', 'sessions.operations.result',
		'sessions.operations.trace.atif_v1_8']
	if app.configured_model() != none {
		features << 'chat.complete'
		features << 'chat.cancel'
		features << 'agent.tools.workspace_readonly'
		features << 'agent.tools.workspace_edit_proposal'
		features << 'agent.tools.shell_command_proposal'
		features << 'agent.tools.skill_read_resource'
	}
	return ctx.json(Capabilities{
		api_version: 'v1'
		features:    features
	})
}

@['/v1/config/model'; get]
pub fn (app &App) get_model_settings(mut ctx Context) veb.Result {
	mut state := app.model_settings
	return ctx.json(state.view())
}

@['/v1/config/model'; post]
pub fn (app &App) update_model_settings(mut ctx Context) veb.Result {
	if ctx.req.data.len > 8_192 {
		return json_request_error(mut ctx, 'model settings request is too large')
	}
	input := json2.decode[ModelSettingsInput](ctx.req.data) or {
		return json_request_error(mut ctx, 'model settings request is invalid')
	}
	mut state := app.model_settings
	state.update(input) or {
		return json_request_error(mut ctx, err.msg())
	}
	return ctx.json(state.view())
}
