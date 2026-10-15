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
		'plugins.catalog', 'plugins.links', 'plugins.components', 'mcp.servers.configured',
		'mcp.credentials', 'mcp.oauth', 'skills.discovery', 'sessions.skills', 'sessions.mcp_servers',
		'workspace.files', 'workspace.read', 'workspace.search', 'workspace.repository_map',
		'workspace.git.worktrees', 'workspace.edits.review', 'workspace.edits.approve',
		'workspace.edits.reject', 'workspace.commands.propose', 'workspace.commands.review',
		'workspace.commands.approve', 'workspace.commands.reject', 'sessions.operations.list',
		'sessions.operations.result', 'sessions.operations.trace.atif_v1_8',
		'sessions.operations.durable_queue', 'sessions.usage.prompt_cache', 'sessions.usage.reasoning']
	if anthropic_prompt_cache_enabled() {
		features << 'provider.anthropic.prompt_cache'
	}
	if openai_prompt_cache_enabled() {
		features << 'provider.openai.prompt_cache'
	}
	if gemini_prompt_cache_enabled() && gemini_cached_content_name().len > 0 {
		features << 'provider.gemini.prompt_cache'
	}
	if shell_sandbox_bubblewrap_capability() {
		features << 'shell.sandbox.bubblewrap'
	}
	if shell_sandbox_seatbelt_capability() {
		features << 'shell.sandbox.seatbelt'
	}
	if shell_sandbox_windows_capability() {
		features << 'shell.sandbox.windows'
	}
	features << 'agent.execution_policy'
	if app.allow_auto_edit {
		features << 'agent.execution_policy.auto_edit'
	}
	if app.allow_autonomous {
		features << 'agent.execution_policy.sandbox_auto'
	}
	if app.configured_model() != none {
		features << 'chat.complete'
		features << 'chat.cancel'
		features << 'agent.tools.workspace_readonly'
		features << 'agent.tools.workspace_edit_proposal'
		features << 'agent.tools.shell_command_proposal'
		features << 'agent.tools.skill_load'
		features << 'agent.tools.skill_read_resource'
		features << 'session.compaction'
		if session_compaction_summarizer_enabled() {
			features << 'session.compaction.summarizer'
		}
		features << 'session.repository_map'
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

@['/v1/config/models'; get]
pub fn (app &App) get_provider_models(mut ctx Context) veb.Result {
	provider := ctx.query['provider'] or {
		return json_request_error(mut ctx, 'provider query parameter is required')
	}
	if provider.len > 100 {
		return json_request_error(mut ctx, 'provider identifier is invalid')
	}
	config := app.provider_model_config(provider, '') or {
		return json_request_error(mut ctx, 'Configure credentials for this provider before listing models')
	}
	models := fetch_provider_models(config) or {
		ctx.res.set_status(.bad_gateway)
		return ctx.json(APIError{
			error: model_catalog_error_message(err.msg())
		})
	}
	return ctx.json(ModelCatalogView{
		provider: provider
		models:   models
	})
}

@['/v1/config/models'; post]
pub fn (app &App) discover_provider_models(mut ctx Context) veb.Result {
	if ctx.req.data.len > 8_192 {
		return json_request_error(mut ctx, 'model catalog request is too large')
	}
	input := json2.decode[ModelCatalogInput](ctx.req.data) or {
		return json_request_error(mut ctx, 'model catalog request is invalid')
	}
	config := app.provider_catalog_model_config(input) or {
		return json_request_error(mut ctx, err.msg())
	}
	models := fetch_provider_models(config) or {
		ctx.res.set_status(.bad_gateway)
		return ctx.json(APIError{
			error: model_catalog_error_message(err.msg())
		})
	}
	return ctx.json(ModelCatalogView{
		provider: config.provider
		models:   models
	})
}

fn model_catalog_error_message(provider_error string) string {
	match provider_error {
		'model catalog endpoint returned HTTP 401' {
			return 'Provider rejected the API key (HTTP 401). Check the key and account.'
		}
		'model catalog endpoint returned HTTP 403' {
			return 'Provider denied model-list access (HTTP 403). Check model access and account permissions.'
		}
		'model catalog endpoint returned HTTP 404' {
			return 'Provider model-list endpoint returned HTTP 404. Check the endpoint or enter a model ID manually.'
		}
		'model catalog endpoint returned HTTP 429' {
			return 'Provider rate-limited model discovery (HTTP 429). Wait before trying again.'
		}
		else {
			return 'Unable to retrieve model list from the configured provider endpoint.'
		}
	}
}

struct ModelCatalogView {
pub:
	provider string
	models   []ModelCatalogEntry
}
