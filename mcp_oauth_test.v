module main

import net.http
import time

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
	// Challenge without a reachable metadata URL still records Bearer fields.
	transport.record_http_auth_challenge('Bearer realm="fixture", resource_metadata="https://auth.example/.well-known/oauth-protected-resource"')
	assert transport.last_auth_challenge.scheme == 'bearer'
	assert transport.last_auth_challenge.realm == 'fixture'
	assert transport.last_auth_challenge.resource_metadata.starts_with('https://auth.example/')
	assert !transport.has_resource_metadata
	message := transport.authorization_required_error()
	assert message.contains('authorization required')
	assert message.contains('resource_metadata=https://auth.example/.well-known/oauth-protected-resource')
}

fn test_parse_mcp_protected_resource_metadata_extracts_authorization_servers() {
	metadata := parse_mcp_protected_resource_metadata('{"resource":"https://mcp.example/mcp","authorization_servers":["https://auth.example/","http://evil.example/"],"scopes_supported":["mcp:tools"],"bearer_methods_supported":["header"]}') or {
		panic(err)
	}
	assert metadata.resource == 'https://mcp.example/mcp'
	assert metadata.authorization_servers == ['https://auth.example/']
	assert metadata.scopes_supported == ['mcp:tools']
	assert metadata.bearer_methods_supported == ['header']
	summary := mcp_protected_resource_metadata_summary(metadata)
	assert summary.contains('authorization_servers=https://auth.example/')
	assert !summary.contains('evil.example')
}

struct MCPOauthMetadataFixture {
mut:
	hits               int
	authorization_base string
}

fn (mut fixture MCPOauthMetadataFixture) handle(request http.Request) http.Response {
	mut response := http.Response{}
	assert request.header.get_custom('Authorization') or { '' } == ''
	if request.method != .get {
		response.set_status(.method_not_allowed)
		return response
	}
	if request.url == '/.well-known/oauth-protected-resource' {
		fixture.hits++
		response.header.set(.content_type, 'application/json')
		response.body = '{"resource":"http://127.0.0.1/mcp","authorization_servers":["${fixture.authorization_base}"],"scopes_supported":["tools"]}'
		return response
	}
	if request.url == '/.well-known/oauth-authorization-server' {
		fixture.hits++
		response.header.set(.content_type, 'application/json')
		response.body = '{"issuer":"${fixture.authorization_base}","authorization_endpoint":"${fixture.authorization_base}/authorize","token_endpoint":"${fixture.authorization_base}/token","registration_endpoint":"${fixture.authorization_base}/register","code_challenge_methods_supported":["S256"]}'
		return response
	}
	response.set_status(.not_found)
	return response
}

fn test_mcp_oauth_authorization_server_metadata_url_inserts_well_known_path() {
	assert mcp_oauth_authorization_server_metadata_url('https://auth.example/') or { '' } == 'https://auth.example/.well-known/oauth-authorization-server'
	assert mcp_oauth_authorization_server_metadata_url('https://auth.example/issuer') or { '' } == 'https://auth.example/.well-known/oauth-authorization-server/issuer'
	assert mcp_oauth_authorization_server_metadata_url('http://evil.example/') == none
}

fn test_parse_mcp_authorization_server_metadata_extracts_endpoints() {
	metadata := parse_mcp_authorization_server_metadata('{"issuer":"https://auth.example/","authorization_endpoint":"https://auth.example/authorize","token_endpoint":"https://auth.example/token","registration_endpoint":"http://evil.example/register","code_challenge_methods_supported":["S256","plain"]}') or {
		panic(err)
	}
	assert metadata.issuer == 'https://auth.example/'
	assert metadata.authorization_endpoint == 'https://auth.example/authorize'
	assert metadata.token_endpoint == 'https://auth.example/token'
	assert metadata.registration_endpoint == ''
	assert metadata.code_challenge_methods_supported == ['S256', 'plain']
	summary := mcp_authorization_server_metadata_summary(metadata)
	assert summary.contains('token_endpoint=https://auth.example/token')
	assert !summary.contains('evil.example')
}

fn test_fetch_mcp_protected_resource_metadata_from_loopback_fixture() {
	mut fixture := &MCPOauthMetadataFixture{}
	mut server := &http.Server{
		accept_timeout:       100 * time.millisecond
		handler:              fixture
		addr:                 '127.0.0.1:0'
		show_startup_message: false
	}
	server_thread := spawn server.listen_and_serve()
	server.wait_till_running() or {
		server.stop()
		server_thread.wait()
		panic(err)
	}
	defer {
		server.stop()
		server_thread.wait()
	}
	fixture.authorization_base = 'http://${server.addr}'
	metadata := fetch_mcp_protected_resource_metadata('http://${server.addr}/.well-known/oauth-protected-resource') or {
		panic(err)
	}
	assert fixture.hits == 1
	assert metadata.authorization_servers == ['http://${server.addr}']
	assert metadata.scopes_supported == ['tools']
	as_metadata := fetch_mcp_authorization_server_metadata(fixture.authorization_base) or {
		panic(err)
	}
	assert fixture.hits == 2
	assert as_metadata.token_endpoint == '${fixture.authorization_base}/token'
	assert as_metadata.code_challenge_methods_supported == ['S256']
	mut transport := &PluginMCPHTTPTransport{
		url: 'http://${server.addr}/mcp'
	}
	transport.record_http_auth_challenge('Bearer realm="live", resource_metadata="http://${server.addr}/.well-known/oauth-protected-resource"')
	assert transport.has_resource_metadata
	assert transport.has_authorization_server_metadata
	assert fixture.hits == 4
	error_text := transport.authorization_required_error()
	assert error_text.contains('authorization_servers=http://${server.addr}')
	assert error_text.contains('token_endpoint=http://${server.addr}/token')
}
