module main

fn test_mcp_oauth_pkce_and_authorize_url_use_s256_and_loopback_redirect() {
	session := build_mcp_oauth_authorize_session(MCPOAuthAuthorizeRequest{
		authorization_endpoint: 'https://auth.example/authorize'
		client_id:              'veasel-local'
		redirect_uri:           'http://127.0.0.1:8765/callback'
		scope:                  'mcp:tools'
		resource:               'https://mcp.example/mcp'
	}, 'https://auth.example/token') or { panic(err) }
	assert session.code_challenge_method == 'S256'
	assert session.code_verifier.len >= min_mcp_oauth_pkce_verifier_len
	assert session.code_challenge.len > 0
	assert session.state.len > 0
	assert session.authorize_url.starts_with('https://auth.example/authorize?')
	assert session.authorize_url.contains('response_type=code')
	assert session.authorize_url.contains('code_challenge_method=S256')
	assert session.authorize_url.contains('redirect_uri=http%3A%2F%2F127.0.0.1%3A8765%2Fcallback')
	assert session.authorize_url.contains('scope=mcp%3Atools')
	assert session.authorize_url.contains('resource=https%3A%2F%2Fmcp.example%2Fmcp')
	assert !session.authorize_url.contains(session.code_verifier)
}

fn test_mcp_oauth_loopback_redirect_rejects_non_loopback() {
	if _ := validate_mcp_oauth_loopback_redirect_uri('https://127.0.0.1/callback') {
		assert false
	}
	if _ := validate_mcp_oauth_loopback_redirect_uri('http://example.com/callback') {
		assert false
	}
	if _ := validate_mcp_oauth_loopback_redirect_uri('http://127.0.0.1/callback#frag') {
		assert false
	}
	assert validate_mcp_oauth_loopback_redirect_uri('http://localhost:9/oauth/cb')! == 'http://localhost:9/oauth/cb'
}

fn test_mcp_oauth_callback_parse_and_state_match() {
	session := build_mcp_oauth_authorize_session(MCPOAuthAuthorizeRequest{
		authorization_endpoint: 'https://auth.example/authorize'
		client_id:              'veasel-local'
		redirect_uri:           'http://127.0.0.1:9/cb'
	}, 'https://auth.example/token') or { panic(err) }
	ok := parse_mcp_oauth_callback_query('http://127.0.0.1:9/cb?code=splendid-code&state=${session.state}') or {
		panic(err)
	}
	assert mcp_oauth_callback_matches_session(session, ok)! == 'splendid-code'
	denied := parse_mcp_oauth_callback_query('error=access_denied&state=${session.state}&error_description=nope') or {
		panic(err)
	}
	if _ := mcp_oauth_callback_matches_session(session, denied) {
		assert false
	} else {
		assert err.msg().contains('access_denied')
	}
	mismatched := MCPOAuthCallbackResult{
		code:  'x'
		state: 'other'
	}
	if _ := mcp_oauth_callback_matches_session(session, mismatched) {
		assert false
	} else {
		assert err.msg().contains('state mismatch')
	}
}
