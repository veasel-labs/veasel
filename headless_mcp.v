module main

import json2
import net.http
import net.urllib
import os
import time

// Headless configured-MCP management. Calls the same /v1/mcp-servers API as the
// TUI. Does not trust servers, approve tool calls, or run install scripts.

enum HeadlessMcpAction {
	list
	add
	enable
	disable
	remove
	credentials_list
	credentials_set
	credentials_remove
	oauth_authorize
	oauth_complete
	oauth_refresh
	oauth_clear_refresh
}

struct HeadlessMcpOptions {
mut:
	action                 HeadlessMcpAction
	scope                  string = configured_mcp_scope_user
	directory              string
	name                   string
	transport              string
	command                string
	args                   []string
	url                    string
	credential             string
	headers                map[string]string
	json                   bool
	authorization_endpoint string
	token_endpoint         string
	client_id              string
	redirect_uri           string
	oauth_scope            string
	resource               string
	oauth_state            string
	oauth_code             string
	callback_url           string
	listen                 bool
	timeout_seconds        int = 180
}

fn print_headless_mcp_help() {
	println('Usage: veasel mcp <list|add|enable|disable|remove|credentials|oauth> [options]\n\nCommands:\n  list [--directory <dir>] [--json]\n  add [user|project] stdio <name> <command> [args…]\n  add [user|project] http <name> <url> [--credential <name>]\n  enable|disable|remove [user|project] <name>\n  credentials list [--json]\n  credentials set <name> --header <Name>=<value> [--header …]\n  credentials remove <name>\n  oauth authorize <credential> --authorization-endpoint <url> --token-endpoint <url> --client-id <id> (--listen | --redirect-uri <url>) [--scope <s>] [--resource <url>] [--timeout <sec>] [--json]\n  oauth complete <credential> (--callback-url <url> | --state <s> --code <c>) [--json]\n  oauth refresh <credential> [--json]\n  oauth clear-refresh <credential> [--json]\n\nOptions:\n  -w, --directory <dir>  Workspace for project scope and list imports (default: cwd)\n      --json             Emit machine-readable JSON\n      --credential <n>   Named HTTP credential for streamable-http add\n      --header <N>=<v>   Header for credentials set (repeatable)\n      --listen           Start a 127.0.0.1 loopback listener, wait for the browser callback, and complete automatically\n  -h, --help             Show this help\n\nPersistence:\n  user         \$VEASEL_DATA_DIR/mcp-servers.json\n  project      <directory>/.veasel/mcp-servers.json\n  credentials  \$VEASEL_DATA_DIR/mcp-credentials.json\n  oauth pending \$VEASEL_DATA_DIR/mcp-oauth-pending.json (owner-only; never printed)\n  oauth refresh \$VEASEL_DATA_DIR/mcp-oauth-refresh.json (owner-only refresh metadata; never printed)\n\nList also reports read-only imports of portable .mcp.json and .cursor/mcp.json.\nTrust remains separate (TUI /mcp trust configured/<name>). No install scripts run.\nStdio processes use your OS privileges; MCP results go to the model provider.\nCredential and OAuth token values are never printed; only names and header names. Credential list may include oauth_refresh=true when refresh metadata exists.')
}

fn parse_headless_mcp_args(args []string, cwd string) !HeadlessMcpOptions {
	mut options := HeadlessMcpOptions{
		directory: cwd
	}
	if args.len == 0 {
		return error('help')
	}
	mut index := 0
	action := args[index]
	index++
	match action {
		'list' {
			options.action = .list
		}
		'add' {
			options.action = .add
		}
		'enable' {
			options.action = .enable
		}
		'disable' {
			options.action = .disable
		}
		'remove' {
			options.action = .remove
		}
		'credentials' {
			if index >= args.len {
				return error('mcp credentials expects list|set|remove')
			}
			sub := args[index]
			index++
			match sub {
				'list' {
					options.action = .credentials_list
				}
				'set' {
					options.action = .credentials_set
				}
				'remove' {
					options.action = .credentials_remove
				}
				'--help', '-h', 'help' {
					return error('help')
				}
				else {
					return error('unknown mcp credentials command: ${sub}')
				}
			}
		}
		'oauth' {
			if index >= args.len {
				return error('mcp oauth expects authorize|complete|refresh|clear-refresh')
			}
			sub := args[index]
			index++
			match sub {
				'authorize' {
					options.action = .oauth_authorize
				}
				'complete' {
					options.action = .oauth_complete
				}
				'refresh' {
					options.action = .oauth_refresh
				}
				'clear-refresh' {
					options.action = .oauth_clear_refresh
				}
				'--help', '-h', 'help' {
					return error('help')
				}
				else {
					return error('unknown mcp oauth command: ${sub}')
				}
			}
		}
		'--help', '-h', 'help' {
			return error('help')
		}
		else {
			return error('unknown mcp command: ${action}')
		}
	}
	mut positional := []string{}
	mut options_done := false
	for index < args.len {
		arg := args[index]
		if !options_done {
			match arg {
				'--' {
					options_done = true
					index++
					continue
				}
				'--directory', '-w' {
					index++
					if index >= args.len || args[index].trim_space().len == 0 {
						return error('--directory expects a workspace path')
					}
					options.directory = args[index]
					index++
					continue
				}
				'--json' {
					options.json = true
					index++
					continue
				}
				'--credential' {
					index++
					if index >= args.len || args[index].trim_space().len == 0 {
						return error('--credential expects a name')
					}
					options.credential = args[index].trim_space()
					index++
					continue
				}
				'--header' {
					index++
					if index >= args.len || args[index].trim_space().len == 0 {
						return error('--header expects Name=value')
					}
					parse_headless_mcp_header(mut options, args[index])!
					index++
					continue
				}
				'--authorization-endpoint' {
					index++
					if index >= args.len || args[index].trim_space().len == 0 {
						return error('--authorization-endpoint expects a URL')
					}
					options.authorization_endpoint = args[index].trim_space()
					index++
					continue
				}
				'--token-endpoint' {
					index++
					if index >= args.len || args[index].trim_space().len == 0 {
						return error('--token-endpoint expects a URL')
					}
					options.token_endpoint = args[index].trim_space()
					index++
					continue
				}
				'--client-id' {
					index++
					if index >= args.len || args[index].trim_space().len == 0 {
						return error('--client-id expects a value')
					}
					options.client_id = args[index].trim_space()
					index++
					continue
				}
				'--redirect-uri' {
					index++
					if index >= args.len || args[index].trim_space().len == 0 {
						return error('--redirect-uri expects a URL')
					}
					options.redirect_uri = args[index].trim_space()
					index++
					continue
				}
				'--scope' {
					index++
					if index >= args.len {
						return error('--scope expects a value')
					}
					options.oauth_scope = args[index].trim_space()
					index++
					continue
				}
				'--resource' {
					index++
					if index >= args.len || args[index].trim_space().len == 0 {
						return error('--resource expects a URL')
					}
					options.resource = args[index].trim_space()
					index++
					continue
				}
				'--state' {
					index++
					if index >= args.len || args[index].trim_space().len == 0 {
						return error('--state expects a value')
					}
					options.oauth_state = args[index].trim_space()
					index++
					continue
				}
				'--code' {
					index++
					if index >= args.len || args[index].trim_space().len == 0 {
						return error('--code expects a value')
					}
					options.oauth_code = args[index].trim_space()
					index++
					continue
				}
				'--callback-url' {
					index++
					if index >= args.len || args[index].trim_space().len == 0 {
						return error('--callback-url expects a URL')
					}
					options.callback_url = args[index].trim_space()
					index++
					continue
				}
				'--listen' {
					options.listen = true
					index++
					continue
				}
				'--timeout' {
					index++
					if index >= args.len || args[index].trim_space().len == 0 {
						return error('--timeout expects seconds')
					}
					options.timeout_seconds = args[index].int()
					if options.timeout_seconds <= 0 || options.timeout_seconds > 3600 {
						return error('--timeout must be between 1 and 3600 seconds')
					}
					index++
					continue
				}
				'--help', '-h' {
					return error('help')
				}
				else {}
			}
		}
		// Stdio args may start with '-' (for example --noop); treat unknown
		// tokens as positionals once option scanning has consumed known flags.
		positional << arg
		index++
	}
	match options.action {
		.list {
			if positional.len > 0 {
				return error('mcp list does not take positional arguments')
			}
		}
		.add {
			parse_headless_mcp_add(mut options, positional)!
		}
		.enable, .disable, .remove {
			parse_headless_mcp_named(mut options, positional)!
		}
		.credentials_list {
			if positional.len > 0 {
				return error('mcp credentials list does not take positional arguments')
			}
		}
		.credentials_set {
			if positional.len != 1 {
				return error('mcp credentials set expects <name>')
			}
			options.name = positional[0]
			if options.headers.len == 0 {
				return error('mcp credentials set requires at least one --header Name=value')
			}
		}
		.credentials_remove {
			if positional.len != 1 {
				return error('mcp credentials remove expects <name>')
			}
			options.name = positional[0]
		}
		.oauth_authorize {
			if positional.len != 1 {
				return error('mcp oauth authorize expects <credential>')
			}
			options.credential = positional[0]
			if options.authorization_endpoint.len == 0 || options.token_endpoint.len == 0
				|| options.client_id.len == 0 {
				return error('mcp oauth authorize requires --authorization-endpoint, --token-endpoint, and --client-id')
			}
			if options.listen {
				if options.redirect_uri.len > 0 {
					return error('--listen does not accept --redirect-uri')
				}
			} else if options.redirect_uri.len == 0 {
				return error('mcp oauth authorize requires --listen or --redirect-uri')
			}
		}
		.oauth_complete {
			if positional.len != 1 {
				return error('mcp oauth complete expects <credential>')
			}
			options.credential = positional[0]
			if options.callback_url.len == 0
				&& (options.oauth_state.len == 0 || options.oauth_code.len == 0) {
				return error('mcp oauth complete requires --callback-url or --state and --code')
			}
		}
		.oauth_refresh {
			if positional.len != 1 {
				return error('mcp oauth refresh expects <credential>')
			}
			options.credential = positional[0]
		}
		.oauth_clear_refresh {
			if positional.len != 1 {
				return error('mcp oauth clear-refresh expects <credential>')
			}
			options.credential = positional[0]
		}
	}
	if options.scope == configured_mcp_scope_project && options.directory.trim_space().len == 0 {
		return error('project-scoped MCP requires --directory')
	}
	return options
}

fn parse_headless_mcp_header(mut options HeadlessMcpOptions, raw string) ! {
	trimmed := raw.trim_space()
	eq := trimmed.index('=') or { -1 }
	if eq <= 0 || eq >= trimmed.len - 1 {
		return error('--header expects Name=value')
	}
	key := trimmed[..eq]
	value := trimmed[eq + 1..]
	if options.headers.len == 0 {
		options.headers = map[string]string{}
	}
	for existing, _ in options.headers {
		if existing.to_lower() == key.to_lower() {
			return error('HTTP header names must be unique regardless of case')
		}
	}
	options.headers[key] = value
}

fn parse_headless_mcp_add(mut options HeadlessMcpOptions, positional []string) ! {
	mut rest := positional.clone()
	if rest.len > 0 && rest[0] in [configured_mcp_scope_user, configured_mcp_scope_project] {
		options.scope = rest[0]
		rest = rest[1..]
	}
	if rest.len < 2 {
		return error('mcp add expects stdio <name> <command> [args…] or http <name> <url>')
	}
	kind := rest[0]
	options.name = rest[1]
	match kind {
		'stdio' {
			if rest.len < 3 {
				return error('mcp add stdio expects <name> <command> [args…]')
			}
			if options.credential.len > 0 {
				return error('stdio servers do not accept --credential')
			}
			options.transport = 'stdio'
			options.command = rest[2]
			options.args = rest[3..]
		}
		'http' {
			if rest.len != 3 {
				return error('mcp add http expects <name> <url>')
			}
			options.transport = 'streamable-http'
			options.url = rest[2]
		}
		else {
			return error('mcp add transport must be stdio or http')
		}
	}
}

fn parse_headless_mcp_named(mut options HeadlessMcpOptions, positional []string) ! {
	mut rest := positional.clone()
	if rest.len > 0 && rest[0] in [configured_mcp_scope_user, configured_mcp_scope_project] {
		options.scope = rest[0]
		rest = rest[1..]
	}
	if rest.len != 1 {
		action := match options.action {
			.enable { 'enable' }
			.disable { 'disable' }
			.remove { 'remove' }
			else { 'manage' }
		}
		return error('mcp ${action} expects [user|project] <name>')
	}
	options.name = rest[0]
}

fn headless_mcp_directory_query(directory string) string {
	trimmed := directory.trim_space()
	if trimmed.len == 0 {
		return ''
	}
	return 'directory=${urllib.query_escape(trimmed)}'
}

fn headless_mcp_scope_query(scope string, directory string) string {
	mut parts := ['scope=${urllib.query_escape(scope)}']
	dir_query := headless_mcp_directory_query(directory)
	if dir_query.len > 0 && scope == configured_mcp_scope_project {
		parts << dir_query
	}
	return parts.join('&')
}

fn headless_mcp_api_error(response http.Response) string {
	decoded := json2.decode[APIError](response.body) or {
		return 'HTTP ${response.status_code}'
	}
	if decoded.error.len > 0 {
		return decoded.error
	}
	return 'HTTP ${response.status_code}'
}

fn execute_headless_mcp_list(port int, options HeadlessMcpOptions) !string {
	query := headless_mcp_directory_query(options.directory)
	path := if query.len > 0 { '/v1/mcp-servers?${query}' } else { '/v1/mcp-servers' }
	response := headless_json_request(port, .get, path, '', false, '')!
	if response.status_code != 200 {
		return error(headless_mcp_api_error(response))
	}
	if options.json {
		return response.body
	}
	catalog := json2.decode[ConfiguredMCPCatalog](response.body)!
	mut lines := []string{cap: catalog.servers.len + 4}
	lines << 'Configured MCP (${catalog.scope})'
	if catalog.path.len > 0 {
		lines << 'user file: ${catalog.path}'
	}
	if catalog.project_path.len > 0 {
		lines << 'project file: ${catalog.project_path}'
	}
	for import_path in catalog.import_paths {
		lines << 'import: ${import_path}'
	}
	if catalog.servers.len == 0 {
		lines << '(none)'
	}
	for server in catalog.servers {
		state := if server.enabled { 'enabled' } else { 'disabled' }
		detail := if server.transport == 'stdio' {
			server.command
		} else {
			server.url_origin
		}
		source := if server.config_file.len > 0 { ' · ${server.config_file}' } else { '' }
		lines << '${state}  configured/${server.name} [${server.transport}] · ${server.scope}${source}  ${detail}'
	}
	return lines.join('\n')
}

fn execute_headless_mcp_add(port int, options HeadlessMcpOptions) !string {
	mut payload := map[string]json2.Any{}
	payload['name'] = options.name
	payload['transport'] = options.transport
	payload['enabled'] = true
	payload['scope'] = options.scope
	if options.scope == configured_mcp_scope_project {
		payload['directory'] = options.directory
	}
	if options.transport == 'stdio' {
		payload['command'] = options.command
		mut args := []json2.Any{cap: options.args.len}
		for argument in options.args {
			args << argument
		}
		payload['args'] = args
	} else {
		payload['url'] = options.url
		if options.credential.len > 0 {
			payload['credential'] = options.credential
		}
	}
	response := headless_json_request(port, .post, '/v1/mcp-servers', json2.encode(payload),
		false, '')!
	if response.status_code != 200 {
		return error(headless_mcp_api_error(response))
	}
	if options.json {
		return response.body
	}
	view := json2.decode[ConfiguredMCPServerView](response.body)!
	return 'Added configured/${view.name} [${view.transport}] (${view.scope}). Trust with the TUI: /mcp trust configured/${view.name}'
}

fn execute_headless_mcp_toggle(port int, options HeadlessMcpOptions, enabled bool) !string {
	query := headless_mcp_scope_query(options.scope, options.directory)
	path := '/v1/mcp-servers/${urllib.path_escape(options.name)}?${query}'
	response := headless_json_request(port, .patch, path, json2.encode({
		'enabled': json2.Any(enabled)
	}), false, '')!
	if response.status_code != 200 {
		return error(headless_mcp_api_error(response))
	}
	if options.json {
		return response.body
	}
	view := json2.decode[ConfiguredMCPServerView](response.body)!
	verb := if enabled { 'Enabled' } else { 'Disabled' }
	return '${verb} configured/${view.name} (${view.scope})'
}

fn execute_headless_mcp_remove(port int, options HeadlessMcpOptions) !string {
	query := headless_mcp_scope_query(options.scope, options.directory)
	path := '/v1/mcp-servers/${urllib.path_escape(options.name)}?${query}'
	response := headless_json_request(port, .delete, path, '', false, '')!
	if response.status_code != 200 {
		return error(headless_mcp_api_error(response))
	}
	if options.json {
		return response.body
	}
	removal := json2.decode[ConfiguredMCPRemoval](response.body)!
	return 'Removed configured/${removal.removed} (${options.scope})'
}

fn execute_headless_mcp_credentials_list(port int, options HeadlessMcpOptions) !string {
	response := headless_json_request(port, .get, '/v1/mcp-credentials', '', false, '')!
	if response.status_code != 200 {
		return error(headless_mcp_api_error(response))
	}
	if options.json {
		return response.body
	}
	catalog := json2.decode[MCPCredentialCatalog](response.body)!
	mut lines := []string{cap: catalog.credentials.len + 2}
	lines << 'MCP credentials'
	if catalog.path.len > 0 {
		lines << 'file: ${catalog.path}'
	}
	if catalog.credentials.len == 0 {
		lines << '(none)'
	}
	for credential in catalog.credentials {
		lines << '${credential.name}  headers: ${credential.header_names.join(', ')}'
	}
	return lines.join('\n')
}

fn execute_headless_mcp_credentials_set(port int, options HeadlessMcpOptions) !string {
	mut headers := map[string]json2.Any{}
	for key, value in options.headers {
		headers[key] = value
	}
	payload := {
		'name':    json2.Any(options.name)
		'headers': json2.Any(headers)
	}
	response := headless_json_request(port, .post, '/v1/mcp-credentials', json2.encode(payload),
		false, '')!
	if response.status_code != 200 {
		return error(headless_mcp_api_error(response))
	}
	if options.json {
		return response.body
	}
	view := json2.decode[MCPCredentialView](response.body)!
	return 'Saved credential ${view.name} (headers: ${view.header_names.join(', ')})'
}

fn execute_headless_mcp_credentials_remove(port int, options HeadlessMcpOptions) !string {
	path := '/v1/mcp-credentials/${urllib.path_escape(options.name)}'
	response := headless_json_request(port, .delete, path, '', false, '')!
	if response.status_code != 200 {
		return error(headless_mcp_api_error(response))
	}
	if options.json {
		return response.body
	}
	removal := json2.decode[MCPCredentialRemoval](response.body)!
	return 'Removed credential ${removal.removed}'
}

fn execute_headless_mcp_oauth_authorize(port int, options HeadlessMcpOptions) !string {
	if options.listen {
		return execute_headless_mcp_oauth_authorize_listen(port, options)
	}
	payload := MCPOAuthAuthorizeInput{
		credential:             options.credential
		authorization_endpoint: options.authorization_endpoint
		token_endpoint:         options.token_endpoint
		client_id:              options.client_id
		redirect_uri:           options.redirect_uri
		scope:                  options.oauth_scope
		resource:               options.resource
	}
	response := headless_json_request(port, .post, '/v1/mcp-oauth/authorize', json2.encode(payload),
		false, '') or { return error('unable to start MCP OAuth: ${err.msg()}') }
	if response.status_code != 200 {
		return error(headless_mcp_api_error(response))
	}
	if options.json {
		return response.body
	}
	view := json2.decode[MCPOAuthAuthorizeView](response.body) or {
		return error('server returned an invalid OAuth authorize response')
	}
	return 'Authorize MCP credential ${view.credential}\nState: ${view.state}\nRedirect: ${view.redirect_uri}\nOpen: ${view.authorize_url}\nThen run: veasel mcp oauth complete ${view.credential} --state ${view.state} --code <code>'
}

fn execute_headless_mcp_oauth_authorize_listen(port int, options HeadlessMcpOptions) !string {
	mut listener := start_mcp_oauth_loopback_listener(mcp_oauth_loopback_default_path, options.timeout_seconds * time.second)!
	payload := MCPOAuthAuthorizeInput{
		credential:             options.credential
		authorization_endpoint: options.authorization_endpoint
		token_endpoint:         options.token_endpoint
		client_id:              options.client_id
		redirect_uri:           listener.redirect_uri()
		scope:                  options.oauth_scope
		resource:               options.resource
	}
	response := headless_json_request(port, .post, '/v1/mcp-oauth/authorize', json2.encode(payload),
		false, '') or {
		listener.close()
		return error('unable to start MCP OAuth: ${err.msg()}')
	}
	if response.status_code != 200 {
		listener.close()
		return error(headless_mcp_api_error(response))
	}
	view := json2.decode[MCPOAuthAuthorizeView](response.body) or {
		listener.close()
		return error('server returned an invalid OAuth authorize response')
	}
	eprintln('Open this URL in a browser to authorize MCP credential `${options.credential}`:')
	eprintln(view.authorize_url)
	callback := listener.wait()!
	if callback.error.len > 0 {
		return error('OAuth authorization failed: ${callback.error}')
	}
	complete_response := headless_json_request(port, .post, '/v1/mcp-oauth/complete',
		json2.encode(MCPOAuthCompleteInput{
			credential: options.credential
			state:      callback.state
			code:       callback.code
		}), false, '') or { return error('unable to complete MCP OAuth: ${err.msg()}') }
	if complete_response.status_code != 200 {
		return error(headless_mcp_api_error(complete_response))
	}
	if options.json {
		return complete_response.body
	}
	cred := json2.decode[MCPCredentialView](complete_response.body) or {
		return error('server returned an invalid credential response')
	}
	return 'Completed OAuth for credential ${cred.name} (headers: ${cred.header_names.join(', ')})'
}

fn execute_headless_mcp_oauth_complete(port int, options HeadlessMcpOptions) !string {
	payload := MCPOAuthCompleteInput{
		credential:   options.credential
		state:        options.oauth_state
		code:         options.oauth_code
		callback_url: options.callback_url
	}
	response := headless_json_request(port, .post, '/v1/mcp-oauth/complete', json2.encode(payload),
		false, '') or { return error('unable to complete MCP OAuth: ${err.msg()}') }
	if response.status_code != 200 {
		return error(headless_mcp_api_error(response))
	}
	if options.json {
		return response.body
	}
	cred := json2.decode[MCPCredentialView](response.body) or {
		return error('server returned an invalid credential response')
	}
	return 'Completed OAuth for credential ${cred.name} (headers: ${cred.header_names.join(', ')})'
}

fn execute_headless_mcp_oauth_refresh(port int, options HeadlessMcpOptions) !string {
	payload := MCPOAuthRefreshInput{
		credential: options.credential
	}
	response := headless_json_request(port, .post, '/v1/mcp-oauth/refresh', json2.encode(payload),
		false, '') or { return error('unable to refresh MCP OAuth: ${err.msg()}') }
	if response.status_code != 200 {
		return error(headless_mcp_api_error(response))
	}
	if options.json {
		return response.body
	}
	cred := json2.decode[MCPCredentialView](response.body) or {
		return error('server returned an invalid credential response')
	}
	return 'Refreshed OAuth for credential ${cred.name} (headers: ${cred.header_names.join(', ')})'
}

fn execute_headless_mcp_oauth_clear_refresh(port int, options HeadlessMcpOptions) !string {
	payload := MCPOAuthRefreshClearInput{
		credential: options.credential
	}
	response := headless_json_request(port, .delete, '/v1/mcp-oauth/refresh', json2.encode(payload),
		false, '') or { return error('unable to clear MCP OAuth refresh: ${err.msg()}') }
	if response.status_code != 200 {
		return error(headless_mcp_api_error(response))
	}
	if options.json {
		return response.body
	}
	cleared := json2.decode[MCPOAuthRefreshClearResult](response.body) or {
		return error('server returned an invalid clear-refresh response')
	}
	return 'Cleared OAuth refresh metadata for credential ${cleared.cleared}'
}

fn execute_headless_mcp_command(port int, args []string) {
	options := parse_headless_mcp_args(args, os.getwd()) or {
		if err.msg() == 'help' {
			print_headless_mcp_help()
			return
		}
		eprintln('veasel: ${err.msg()}')
		print_headless_mcp_help()
		exit(2)
	}
	ensure_backend(port, '') or {
		eprintln('veasel: ${err.msg()}')
		exit(1)
	}
	output := match options.action {
		.list {
			execute_headless_mcp_list(port, options) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
		.add {
			execute_headless_mcp_add(port, options) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
		.enable {
			execute_headless_mcp_toggle(port, options, true) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
		.disable {
			execute_headless_mcp_toggle(port, options, false) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
		.remove {
			execute_headless_mcp_remove(port, options) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
		.credentials_list {
			execute_headless_mcp_credentials_list(port, options) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
		.credentials_set {
			execute_headless_mcp_credentials_set(port, options) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
		.credentials_remove {
			execute_headless_mcp_credentials_remove(port, options) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
		.oauth_authorize {
			execute_headless_mcp_oauth_authorize(port, options) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
		.oauth_complete {
			execute_headless_mcp_oauth_complete(port, options) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
		.oauth_refresh {
			execute_headless_mcp_oauth_refresh(port, options) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
		.oauth_clear_refresh {
			execute_headless_mcp_oauth_clear_refresh(port, options) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
	}
	println(output)
}
