module main

import json2

pub struct MCPOAuthAuthorizeInput {
pub:
	credential             string
	authorization_endpoint string
	token_endpoint         string
	client_id              string
	redirect_uri           string
	scope                  string
	resource               string
}

pub struct MCPOAuthAuthorizeView {
pub:
	credential            string
	state                 string
	authorize_url         string @[json: 'authorize_url']
	redirect_uri          string @[json: 'redirect_uri']
	code_challenge_method string @[json: 'code_challenge_method']
}

pub struct MCPOAuthCompleteInput {
pub:
	credential   string
	state        string
	code         string
	callback_url string @[json: 'callback_url'; omitempty]
}

fn decode_mcp_oauth_authorize_input(raw string) !MCPOAuthAuthorizeInput {
	fields := json2.decode[map[string]json2.Any](raw) or {
		return error('Expected OAuth authorize JSON object')
	}
	credential := json_required_string(fields, 'credential')!
	if !is_valid_mcp_credential_name(credential) {
		return error('MCP credential name is invalid')
	}
	return MCPOAuthAuthorizeInput{
		credential:             credential
		authorization_endpoint: json_required_string(fields, 'authorization_endpoint')!
		token_endpoint:         json_required_string(fields, 'token_endpoint')!
		client_id:              json_required_string(fields, 'client_id')!
		redirect_uri:           json_required_string(fields, 'redirect_uri')!
		scope:                  json_optional_string(fields, 'scope')
		resource:               json_optional_string(fields, 'resource')
	}
}

fn decode_mcp_oauth_complete_input(raw string) !MCPOAuthCompleteInput {
	fields := json2.decode[map[string]json2.Any](raw) or {
		return error('Expected OAuth complete JSON object')
	}
	credential := json_required_string(fields, 'credential')!
	if !is_valid_mcp_credential_name(credential) {
		return error('MCP credential name is invalid')
	}
	return MCPOAuthCompleteInput{
		credential:   credential
		state:        json_optional_string(fields, 'state')
		code:         json_optional_string(fields, 'code')
		callback_url: json_optional_string(fields, 'callback_url')
	}
}

fn json_required_string(fields map[string]json2.Any, key string) !string {
	value := fields[key] or { return error('`${key}` is required') }
	if value !is string {
		return error('`${key}` must be a string')
	}
	trimmed := (value as string).trim_space()
	if trimmed.len == 0 {
		return error('`${key}` is required')
	}
	return trimmed
}

fn json_optional_string(fields map[string]json2.Any, key string) string {
	value := fields[key] or { return '' }
	if value !is string {
		return ''
	}
	return (value as string).trim_space()
}

fn (app &App) start_mcp_oauth_authorize(input MCPOAuthAuthorizeInput) !MCPOAuthAuthorizeView {
	session := build_mcp_oauth_authorize_session(MCPOAuthAuthorizeRequest{
		authorization_endpoint: input.authorization_endpoint
		client_id:              input.client_id
		redirect_uri:           input.redirect_uri
		scope:                  input.scope
		resource:               input.resource
	}, input.token_endpoint)!
	mut pending := app.mcp_oauth_pending
	pending.put(session)!
	return MCPOAuthAuthorizeView{
		credential:            input.credential
		state:                 session.state
		authorize_url:         session.authorize_url
		redirect_uri:          session.redirect_uri
		code_challenge_method: session.code_challenge_method
	}
}

fn (app &App) complete_mcp_oauth_authorize(input MCPOAuthCompleteInput) !MCPCredentialView {
	mut callback := MCPOAuthCallbackResult{}
	if input.callback_url.len > 0 {
		callback = parse_mcp_oauth_callback_query(input.callback_url)!
	} else {
		if input.state.len == 0 || input.code.len == 0 {
			return error('OAuth complete requires code and state, or callback_url')
		}
		callback = MCPOAuthCallbackResult{
			code:  input.code
			state: input.state
		}
	}
	mut pending := app.mcp_oauth_pending
	mut credentials := app.mcp_credentials
	mut refresh := app.mcp_oauth_refresh
	view := complete_mcp_oauth_authorization_code(mut pending, mut credentials, mut refresh,
		input.credential, callback)!
	return app.with_mcp_oauth_refresh_flag(view)
}

pub struct MCPOAuthRefreshInput {
pub:
	credential string
}

fn decode_mcp_oauth_refresh_input(raw string) !MCPOAuthRefreshInput {
	fields := json2.decode[map[string]json2.Any](raw) or {
		return error('Expected OAuth refresh JSON object')
	}
	credential := json_required_string(fields, 'credential')!
	if !is_valid_mcp_credential_name(credential) {
		return error('MCP credential name is invalid')
	}
	return MCPOAuthRefreshInput{
		credential: credential
	}
}

fn (app &App) refresh_mcp_oauth_authorize(input MCPOAuthRefreshInput) !MCPCredentialView {
	mut refresh := app.mcp_oauth_refresh
	mut credentials := app.mcp_credentials
	view := refresh_mcp_oauth_credential(mut refresh, mut credentials, input.credential)!
	return app.with_mcp_oauth_refresh_flag(view)
}

pub struct MCPOAuthRefreshClearInput {
pub:
	credential string
}

pub struct MCPOAuthRefreshClearResult {
pub:
	cleared string
}

fn decode_mcp_oauth_refresh_clear_input(raw string) !MCPOAuthRefreshClearInput {
	fields := json2.decode[map[string]json2.Any](raw) or {
		return error('Expected OAuth refresh clear JSON object')
	}
	credential := json_required_string(fields, 'credential')!
	if !is_valid_mcp_credential_name(credential) {
		return error('MCP credential name is invalid')
	}
	return MCPOAuthRefreshClearInput{
		credential: credential
	}
}

fn (app &App) with_mcp_oauth_refresh_flag(view MCPCredentialView) MCPCredentialView {
	mut refresh := app.mcp_oauth_refresh
	return MCPCredentialView{
		name:          view.name
		header_names:  view.header_names
		oauth_refresh: refresh.has(view.name)
	}
}

fn (app &App) mcp_credential_catalog() MCPCredentialCatalog {
	mut credentials := app.mcp_credentials
	mut refresh := app.mcp_oauth_refresh
	catalog := credentials.view()
	mut views := []MCPCredentialView{cap: catalog.credentials.len}
	for view in catalog.credentials {
		views << MCPCredentialView{
			name:          view.name
			header_names:  view.header_names
			oauth_refresh: refresh.has(view.name)
		}
	}
	return MCPCredentialCatalog{
		path:        catalog.path
		credentials: views
	}
}

fn (app &App) clear_mcp_oauth_refresh(input MCPOAuthRefreshClearInput) !MCPOAuthRefreshClearResult {
	mut refresh := app.mcp_oauth_refresh
	refresh.remove(input.credential)!
	return MCPOAuthRefreshClearResult{
		cleared: input.credential
	}
}

fn (app &App) remove_mcp_credential_and_oauth(name string) ! {
	mut credentials := app.mcp_credentials
	mut refresh := app.mcp_oauth_refresh
	credentials.remove(name)!
	refresh.remove(name) or {}
}
