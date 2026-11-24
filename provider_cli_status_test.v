module main

fn status_test_spec() ProviderCliSpec {
	return ProviderCliSpec{
		id:                      'codex'
		name:                    'OpenAI Codex'
		exec:                    'codex'
		protocol:                'app-server'
		auth_probe_path:         '~/.codex/auth.json'
		permission_modes:        ['ask', 'accept-edits']
		session_resume_verified: true
		usage_reporting:         'not-published'
	}
}

fn test_provider_cli_status_reports_facts_without_claiming_signin() {
	status := provider_cli_status_from_probe(status_test_spec(), '/usr/bin/codex', 'codex-cli 0.169.0', true)
	assert status.installed
	assert status.version == 'codex-cli 0.169.0'
	assert status.auth_probe_present
	// File presence is never reported as a verified sign-in.
	assert status.auth_state == 'probe-present'
	assert status.protocol == 'app-server'
	assert status.usage_reporting == 'not-published'
}

fn test_provider_cli_status_missing_binary_and_auth() {
	status := provider_cli_status_from_probe(status_test_spec(), '', '', false)
	assert !status.installed
	assert status.version == ''
	assert !status.auth_probe_present
	assert status.auth_state == 'probe-missing'
}

fn test_provider_cli_statuses_cover_registry() {
	statuses := provider_cli_statuses()
	assert statuses.len == provider_cli_registry().len
	for status in statuses {
		assert status.id.len > 0
		assert status.auth_state in ['verified', 'signed-out', 'probe-present', 'probe-missing',
			'unknown']
	}
}

fn test_claude_native_auth_status_verifies_login_without_exposing_identity() {
	spec := provider_cli_by_id('claude-code') or { panic('missing Claude CLI spec') }
	result := provider_cli_auth_result(spec, 0, '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max","email":"private@example.test"}')
	assert result.state == 'verified'
	assert result.method == 'claude.ai'
	assert result.account_mode == 'max'
	status := provider_cli_status_with_auth(spec, '/usr/bin/claude', '2.1.330', false, result)
	assert status.auth_state == 'verified' // Native CLI login wins even without a credential file.
	assert !status.auth_probe_present
	assert status.auth_method == 'claude.ai'
	assert status.account_mode == 'max'
}

fn test_claude_native_auth_status_reports_signed_out_and_rejects_unknown_shapes() {
	spec := provider_cli_by_id('claude-code') or { panic('missing Claude CLI spec') }
	logged_out := provider_cli_auth_result(spec, 0, '{"loggedIn":false}')
	assert logged_out.state == 'signed-out'
	assert logged_out.method == ''
	assert logged_out.account_mode == ''
	malformed := provider_cli_auth_result(spec, 0, '{"status":"logged in"}')
	assert malformed.state == ''
	assert malformed.error == 'unrecognized-status-response'
	failed := provider_cli_auth_result(spec, 1, 'private diagnostic output')
	assert failed.state == ''
	assert failed.error == 'status-command-failed'
}

fn test_codex_native_auth_status_uses_only_known_account_modes() {
	spec := provider_cli_by_id('codex') or { panic('missing Codex CLI spec') }
	chatgpt := provider_cli_auth_result(spec, 0, 'Logged in using ChatGPT')
	assert chatgpt.state == 'verified'
	assert chatgpt.method == 'chatgpt'
	assert chatgpt.account_mode == '' // CLI does not report the subscription plan.
	api_key := provider_cli_auth_result(spec, 0, 'Logged in using API key')
	assert api_key.state == 'verified'
	assert api_key.method == 'api-key'
	logged_out := provider_cli_auth_result(spec, 0, 'Not logged in')
	assert logged_out.state == 'signed-out'
	unknown := provider_cli_auth_result(spec, 0, 'Logged in as private@example.test')
	assert unknown.state == ''
	assert unknown.error == 'unrecognized-status-response'
}

fn test_unverified_providers_keep_presence_only_auth_state() {
	opencode := provider_cli_by_id('opencode') or { panic('missing OpenCode CLI spec') }
	assert opencode.auth_status_kind == ''
	status := provider_cli_status_with_auth(opencode, '/usr/bin/opencode', 'opencode 2.4.1', true, ProviderCliAuthResult{})
	assert status.auth_state == 'probe-present'
	assert status.auth_method == ''
	assert status.account_mode == ''
}
