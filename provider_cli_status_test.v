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
	status := provider_cli_status_from_probe(status_test_spec(), '/usr/bin/codex',
		'codex-cli 0.169.0', true)
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
		assert status.auth_state in ['probe-present', 'probe-missing', 'unknown']
	}
}
