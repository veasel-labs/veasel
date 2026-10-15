module main

import net.http
import net.urllib
import os
import time
import uuid

struct MCPOAuthTokenFixture {
mut:
	hits            int
	expected_code   string
	expected_verify string
	last_body       string
}

fn (mut fixture MCPOAuthTokenFixture) handle(request http.Request) http.Response {
	mut response := http.Response{}
	if request.url != '/token' || request.method != .post {
		response.set_status(.not_found)
		return response
	}
	fixture.hits++
	fixture.last_body = request.data
	assert (request.header.get(.content_type) or { '' }).starts_with('application/x-www-form-urlencoded')
	values := urllib.parse_query(request.data) or {
		response.set_status(.bad_request)
		return response
	}
	if (values.get('grant_type') or { '' }) != 'authorization_code'
		|| (values.get('code') or { '' }) != fixture.expected_code
		|| (values.get('code_verifier') or { '' }) != fixture.expected_verify {
		response.set_status(.bad_request)
		response.body = '{"error":"invalid_grant"}'
		return response
	}
	response.header.set(.content_type, 'application/json')
	response.body = '{"access_token":"access-secret-token","token_type":"Bearer","expires_in":3600,"refresh_token":"refresh-secret","scope":"mcp:tools"}'
	return response
}

fn test_parse_mcp_oauth_token_response_requires_access_token() {
	tokens := parse_mcp_oauth_token_response('{"access_token":"abc","token_type":"Bearer","expires_in":60}') or {
		panic(err)
	}
	assert tokens.access_token == 'abc'
	assert tokens.token_type == 'bearer'
	assert tokens.expires_in == 60
	if _ := parse_mcp_oauth_token_response('{"token_type":"Bearer"}') {
		assert false
	}
}

fn test_exchange_mcp_oauth_authorization_code_and_apply_credential() {
	mut fixture := &MCPOAuthTokenFixture{}
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
	session := build_mcp_oauth_authorize_session(MCPOAuthAuthorizeRequest{
		authorization_endpoint: 'http://${server.addr}/authorize'
		client_id:              'veasel-local'
		redirect_uri:           'http://127.0.0.1:9/cb'
		scope:                  'mcp:tools'
	}, 'http://${server.addr}/token') or { panic(err) }
	fixture.expected_code = 'auth-code-1'
	fixture.expected_verify = session.code_verifier

	pending_path := os.join_path(os.temp_dir(), 'veasel-oauth-pending-${uuid.new_v4().str()}.json')
	cred_path := os.join_path(os.temp_dir(), 'veasel-oauth-creds-${uuid.new_v4().str()}.json')
	defer {
		os.rm(pending_path) or {}
		os.rm(cred_path) or {}
	}
	mut pending := new_mcp_oauth_pending_state(pending_path)
	pending.put(session) or { panic(err) }
	mut credentials := new_mcp_credential_state(cred_path)
	view := complete_mcp_oauth_authorization_code(mut pending, mut credentials, 'mcp-oauth',
		MCPOAuthCallbackResult{
			code:  'auth-code-1'
			state: session.state
		}) or { panic(err) }
	assert view.name == 'mcp-oauth'
	assert view.header_names == ['Authorization']
	assert fixture.hits == 1
	assert fixture.last_body.contains('code_verifier=')
	assert !fixture.last_body.contains('access-secret-token')
	headers := credentials.get_headers('mcp-oauth') or { panic(err) }
	assert headers['Authorization'] == 'Bearer access-secret-token'
	// Pending session is consumed.
	if _ := pending.take(session.state) {
		assert false
	}
	// Pending file is owner-restricted when present.
	$if !windows {
		if os.is_file(pending_path) {
			assert os.inode(pending_path).bitmask() == 0o600
		}
	}
}
