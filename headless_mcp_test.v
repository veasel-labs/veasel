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
}

fn test_headless_mcp_query_helpers_escape_paths() {
	assert headless_mcp_directory_query('/tmp/my workspace').contains('directory=')
	assert headless_mcp_directory_query('/tmp/my workspace').contains('%20')
		|| headless_mcp_directory_query('/tmp/my workspace').contains('+')
	assert headless_mcp_scope_query(configured_mcp_scope_project, '/tmp/ws').contains('scope=project')
	assert headless_mcp_scope_query(configured_mcp_scope_project, '/tmp/ws').contains('directory=')
	assert !headless_mcp_scope_query(configured_mcp_scope_user, '/tmp/ws').contains('directory=')
}
