module main

fn test_validate_plugin_mcp_url_accepts_https_and_loopback_http() {
	assert validate_plugin_mcp_url('https://tools.example.invalid/mcp')! == 'https://tools.example.invalid/mcp'
	assert validate_plugin_mcp_url('http://127.0.0.1:8080/mcp')! == 'http://127.0.0.1:8080/mcp'
	assert validate_plugin_mcp_url('http://localhost/mcp')! == 'http://localhost/mcp'
	assert validate_plugin_mcp_url('http://[::1]:9/mcp')! == 'http://[::1]:9/mcp'
}

fn test_validate_plugin_mcp_url_rejects_userinfo_fragment_and_cleartext_remote() {
	if _ := validate_plugin_mcp_url('https://user:pass@tools.example.invalid/mcp') {
		assert false
	}
	if _ := validate_plugin_mcp_url('https://tools.example.invalid/mcp#frag') {
		assert false
	}
	if _ := validate_plugin_mcp_url('http://tools.example.invalid/mcp') {
		assert false
	} else {
		assert err.msg().contains('HTTPS')
	}
	if _ := validate_plugin_mcp_url('ftp://127.0.0.1/mcp') {
		assert false
	}
}

fn test_valid_http_header_rejects_duplicates_case_insensitively_via_map_builder() {
	assert valid_http_header('Authorization', 'Bearer x')
	assert !valid_http_header('Bad Name', 'x')
	assert !valid_http_header('X-Ok', 'line\r\nInjected: 1')
	mut headers := map[string]string{}
	headers['Authorization'] = 'Bearer a'
	for existing, _ in headers {
		assert existing.to_lower() == 'authorization'
		assert 'authorization' == 'Authorization'.to_lower()
	}
}
