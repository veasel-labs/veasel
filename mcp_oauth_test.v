module main

fn test_parse_www_authenticate_bearer_extracts_rfc9728_resource_metadata() {
	challenge := parse_www_authenticate_bearer('Bearer realm="mcp", scope="tools", resource_metadata="https://auth.example/oauth/protected-resource", error="invalid_token", error_description="expired"') or {
		assert false, 'expected Bearer challenge'
		return
	}
	assert challenge.scheme == 'bearer'
	assert challenge.realm == 'mcp'
	assert challenge.scope == 'tools'
	assert challenge.resource_metadata == 'https://auth.example/oauth/protected-resource'
	assert challenge.error == 'invalid_token'
	assert challenge.error_description == 'expired'
	summary := mcp_auth_challenge_summary(challenge)
	assert summary.contains('resource_metadata=https://auth.example/oauth/protected-resource')
	assert summary.contains('realm=mcp')
}

fn test_parse_www_authenticate_skips_non_bearer_and_rejects_unsafe_metadata() {
	challenges := parse_www_authenticate_challenges('Basic realm="x", Bearer realm="y", resource_metadata="http://evil.example/meta"')
	assert challenges.len == 2
	assert challenges[0].scheme == 'basic'
	assert challenges[0].realm == 'x'
	assert challenges[1].scheme == 'bearer'
	assert challenges[1].realm == 'y'
	assert challenges[1].resource_metadata == ''
	assert parse_www_authenticate_bearer('Basic realm="only"') == none
	loopback := parse_www_authenticate_bearer('Bearer resource_metadata="http://127.0.0.1:9/.well-known/oauth-protected-resource"') or {
		assert false, 'loopback http metadata must be accepted'
		return
	}
	assert loopback.resource_metadata == 'http://127.0.0.1:9/.well-known/oauth-protected-resource'
	assert validate_mcp_oauth_resource_metadata_url('https://user:pass@example.com/meta') == none
	assert validate_mcp_oauth_resource_metadata_url('https://example.com/meta#frag') == none
}

fn test_plugin_mcp_http_transport_surfaces_bearer_auth_challenge_on_401() {
	mut transport := &PluginMCPHTTPTransport{
		url: 'https://example.com/mcp'
	}
	// Direct unit path: emulate a recorded 401 challenge without a live server.
	transport.record_http_auth_challenge('Bearer realm="fixture", resource_metadata="https://auth.example/.well-known/oauth-protected-resource"')
	assert transport.last_auth_challenge.scheme == 'bearer'
	assert transport.last_auth_challenge.realm == 'fixture'
	assert transport.last_auth_challenge.resource_metadata.starts_with('https://auth.example/')
	message := transport.authorization_required_error()
	assert message.contains('authorization required')
	assert message.contains('resource_metadata=https://auth.example/.well-known/oauth-protected-resource')
}
