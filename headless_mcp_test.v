module main

fn test_headless_mcp_parses_list_add_toggle_and_remove() {
	listed := parse_headless_mcp_args(['list', '--directory', '/tmp/ws', '--json'], '/tmp') or {
		panic(err)
	}
	assert listed.action == .list
	assert listed.directory == '/tmp/ws'
	assert listed.json

	stdio := parse_headless_mcp_args([
		'add',
		'project',
		'stdio',
		'echo-tools',
		'true',
		'--noop',
		'-w',
		'/tmp/project',
	], '/tmp') or { panic(err) }
	assert stdio.action == .add
	assert stdio.scope == configured_mcp_scope_project
	assert stdio.transport == 'stdio'
	assert stdio.name == 'echo-tools'
	assert stdio.command == 'true'
	assert stdio.args == ['--noop']
	assert stdio.directory == '/tmp/project'

	http := parse_headless_mcp_args(['add', 'http', 'docs', 'https://example.com/mcp'],
		'/tmp') or { panic(err) }
	assert http.scope == configured_mcp_scope_user
	assert http.transport == 'streamable-http'
	assert http.url == 'https://example.com/mcp'

	enabled := parse_headless_mcp_args(['enable', 'project', 'echo-tools', '--directory', '/tmp/project'], '/tmp') or { panic(err) }
	assert enabled.action == .enable
	assert enabled.scope == configured_mcp_scope_project
	assert enabled.name == 'echo-tools'

	removed := parse_headless_mcp_args(['remove', 'echo-tools'], '/tmp') or { panic(err) }
	assert removed.action == .remove
	assert removed.scope == configured_mcp_scope_user
	assert removed.name == 'echo-tools'
}

fn test_headless_mcp_parses_oauth_commands() {
	authorize := parse_headless_mcp_args([
		'oauth',
		'authorize',
		'mcp-token',
		'--authorization-endpoint',
		'https://auth.example/authorize',
		'--token-endpoint',
		'https://auth.example/token',
		'--client-id',
		'veasel-local',
		'--listen',
		'--scope',
		'mcp:tools',
		'--timeout',
		'60',
		'--json',
	], '/tmp') or { panic(err) }
	assert authorize.action == .oauth_authorize
	assert authorize.credential == 'mcp-token'
	assert authorize.authorization_endpoint == 'https://auth.example/authorize'
	assert authorize.token_endpoint == 'https://auth.example/token'
	assert authorize.client_id == 'veasel-local'
	assert authorize.listen
	assert authorize.timeout_seconds == 60
	assert authorize.json

	manual := parse_headless_mcp_args([
		'oauth',
		'authorize',
		'mcp-token',
		'--authorization-endpoint',
		'https://auth.example/authorize',
		'--token-endpoint',
		'https://auth.example/token',
		'--client-id',
		'veasel-local',
		'--redirect-uri',
		'http://127.0.0.1:9/cb',
	], '/tmp') or { panic(err) }
	assert manual.redirect_uri == 'http://127.0.0.1:9/cb'
	assert !manual.listen

	complete := parse_headless_mcp_args([
		'oauth',
		'complete',
		'mcp-token',
		'--state',
		'abc',
		'--code',
		'def',
	], '/tmp') or { panic(err) }
	assert complete.action == .oauth_complete
	assert complete.credential == 'mcp-token'
	assert complete.oauth_state == 'abc'
	assert complete.oauth_code == 'def'

	if _ := parse_headless_mcp_args([
		'oauth',
		'authorize',
		'mcp-token',
		'--authorization-endpoint',
		'https://auth.example/authorize',
		'--token-endpoint',
		'https://auth.example/token',
		'--client-id',
		'veasel-local',
	], '/tmp') {
		assert false
	}
}

fn test_headless_mcp_parses_credentials_commands() {
	listed := parse_headless_mcp_args(['credentials', 'list', '--json'], '/tmp') or { panic(err) }
	assert listed.action == .credentials_list
	assert listed.json

	set := parse_headless_mcp_args([
		'credentials',
		'set',
		'docs-token',
		'--header',
		'Authorization=Bearer secret',
		'--header',
		'X-Tenant=acme',
	], '/tmp') or { panic(err) }
	assert set.action == .credentials_set
	assert set.name == 'docs-token'
	assert set.headers['Authorization'] == 'Bearer secret'
	assert set.headers['X-Tenant'] == 'acme'

	http := parse_headless_mcp_args([
		'add',
		'http',
		'docs',
		'https://example.com/mcp',
		'--credential',
		'docs-token',
	], '/tmp') or { panic(err) }
	assert http.transport == 'streamable-http'
	assert http.credential == 'docs-token'

	removed := parse_headless_mcp_args(['credentials', 'remove', 'docs-token'], '/tmp') or {
		panic(err)
	}
	assert removed.action == .credentials_remove
	assert removed.name == 'docs-token'
}

fn test_headless_mcp_rejects_invalid_shapes() {
	if _ := parse_headless_mcp_args(['add', 'sse', 'name', 'http://x'], '/tmp') {
		assert false
	} else {
		assert err.msg().contains('stdio or http')
	}
	if _ := parse_headless_mcp_args(['enable'], '/tmp') {
		assert false
	} else {
		assert err.msg().contains('expects')
	}
	if _ := parse_headless_mcp_args(['list', 'extra'], '/tmp') {
		assert false
	} else {
		assert err.msg().contains('positional')
	}
	if _ := parse_headless_mcp_args(['mystery'], '/tmp') {
		assert false
	} else {
		assert err.msg().contains('unknown mcp command')
	}
	if _ := parse_headless_mcp_args(['credentials', 'set', 'x'], '/tmp') {
		assert false
	} else {
		assert err.msg().contains('--header')
	}
	if _ := parse_headless_mcp_args(['add', 'stdio', 'x', 'true', '--credential', 'y'], '/tmp') {
		assert false
	} else {
		assert err.msg().contains('credential')
	}
}

fn test_headless_mcp_query_helpers_escape_paths() {
	assert headless_mcp_directory_query('/tmp/my workspace').contains('directory=')
	assert headless_mcp_directory_query('/tmp/my workspace').contains('%20')
		|| headless_mcp_directory_query('/tmp/my workspace').contains('+')
	assert headless_mcp_scope_query(configured_mcp_scope_project, '/tmp/ws').contains('scope=project')
	assert headless_mcp_scope_query(configured_mcp_scope_project, '/tmp/ws').contains('directory=')
	assert !headless_mcp_scope_query(configured_mcp_scope_user, '/tmp/ws').contains('directory=')
}
