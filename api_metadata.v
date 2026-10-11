module main

import veb

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
		'workspace.commands.approve', 'workspace.commands.reject']
	if configured_model() != none {
		features << 'chat.complete'
		features << 'chat.cancel'
		features << 'agent.tools.workspace_readonly'
		features << 'agent.tools.workspace_edit_proposal'
		features << 'agent.tools.shell_command_proposal'
	}
	return ctx.json(Capabilities{
		api_version: 'v1'
		features:    features
	})
}
