module main

import json2
import net.http
import net.urllib
import os
import time
import uuid

struct MCPOAuthApiTokenFixture {
mut:
	expected_code   string
	expected_verify string
}

fn (mut fixture MCPOAuthApiTokenFixture) handle(request http.Request) http.Response {
	mut response := http.Response{}
	if request.url != '/token' || request.method != .post {
		response.set_status(.not_found)
		return response
	}
	values := urllib.parse_query(request.data) or {
		response.set_status(.bad_request)
		return response
	}
	if (values.get('code') or { '' }) != fixture.expected_code
		|| (values.get('code_verifier') or { '' }) != fixture.expected_verify {
		response.set_status(.bad_request)
		return response
	}
	response.header.set(.content_type, 'application/json')
	response.body = '{"access_token":"api-access-token","token_type":"bearer","expires_in":120}'
	return response
}

fn test_mcp_oauth_api_authorize_and_complete_upsert_credential() {
	mut fixture := &MCPOAuthApiTokenFixture{}
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
	data_dir := os.join_path(os.temp_dir(), 'veasel-oauth-api-${uuid.new_v4().str()}')
	os.mkdir_all(data_dir) or { panic(err) }
	defer { os.rmdir_all(data_dir) or {} }
	mut store := open_store(os.join_path(data_dir, 'veasel.db')) or { panic(err) }
	defer { store.close() or {} }
	plugin_directory := os.join_path(data_dir, 'plugins')
	os.mkdir_all(plugin_directory) or { panic(err) }
	mut app := new_app(store, plugin_directory)
	defer { app.close() }
	started := app.start_mcp_oauth_authorize(MCPOAuthAuthorizeInput{
		credential:             'oauth-cred'
		authorization_endpoint: 'http://${server.addr}/authorize'
		token_endpoint:         'http://${server.addr}/token'
		client_id:              'veasel-local'
		redirect_uri:           'http://127.0.0.1:9/cb'
		scope:                  'mcp:tools'
	}) or { panic(err) }
	assert started.credential == 'oauth-cred'
	assert started.authorize_url.contains('code_challenge_method=S256')
	assert !json2.encode(started).contains('code_verifier')
	mut pending := app.mcp_oauth_pending
	pending.mu.lock()
	session := pending.sessions[started.state]
	pending.mu.unlock()
	fixture.expected_code = 'from-browser'
	fixture.expected_verify = session.code_verifier
	view := app.complete_mcp_oauth_authorize(MCPOAuthCompleteInput{
		credential:   'oauth-cred'
		callback_url: 'http://127.0.0.1:9/cb?code=from-browser&state=${started.state}'
	}) or { panic(err) }
	assert view.name == 'oauth-cred'
	assert view.header_names == ['Authorization']
	mut credentials := app.mcp_credentials
	headers := credentials.get_headers('oauth-cred') or { panic(err) }
	assert headers['Authorization'] == 'Bearer api-access-token'
}
