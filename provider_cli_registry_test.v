module main

fn test_provider_cli_registry_is_truthful() {
	registry := provider_cli_registry()
	assert registry.len == 5
	for spec in registry {
		assert spec.exec.len > 0
		if spec.id != 'cursor-agent' {
			assert spec.permission_modes.len > 0
		}
		if spec.id == 'claude-code' {
			assert spec.auth_status_args == ['auth', 'status', '--json']
			assert spec.auth_status_kind == 'claude-json'
		}
		if spec.id == 'codex' {
			assert spec.auth_status_args == ['login', 'status']
			assert spec.auth_status_kind == 'codex-text'
		}
		// Muse ACP was measured live (1.4.20), so it is launchable in
		// ask mode; resume and usage stay unverified until exercised.
		if spec.id == 'muse' {
			assert spec.protocol == 'acp'
			assert !spec.session_resume_verified
			assert spec.usage_reporting == 'unknown'
		}
		if spec.id == 'cursor-agent' {
			assert spec.exec == 'cursor-agent'
			assert spec.protocol == 'acp'
			assert spec.auth_status_args == ['status', '--format', 'json']
			assert spec.auth_status_kind == 'cursor-json'
			assert spec.permission_modes.len == 0
			assert spec.launch_blocked_reason.contains('authenticate(cursor_login)')
		}
		if spec.id in ['opencode', 'muse'] {
			assert spec.auth_status_args.len == 0
			assert spec.auth_status_kind == ''
		}
	}
}

fn test_validate_provider_cli_launch_fails_closed() {
	claude := validate_provider_cli_launch('claude-code', 'ask') or { panic(err) }
	assert claude.protocol == 'stream-json'
	opencode_bypass := validate_provider_cli_launch('opencode', 'bypass') or {
		assert err.msg().contains('does not support permission mode')
		ProviderCliSpec{}
	}
	assert opencode_bypass.id == '' // rejected above
	muse := validate_provider_cli_launch('muse', 'ask') or { panic(err) }
	assert muse.protocol == 'acp'
	if _ := validate_provider_cli_launch('muse', 'bypass') {
		panic('muse must refuse non-ask permission modes')
	}
	if _ := validate_provider_cli_launch('nope', 'ask') {
		panic('unknown provider must refuse to launch')
	}
	cursor := validate_provider_cli_launch('cursor-agent', 'ask') or {
		assert err.msg().contains('not launchable')
		ProviderCliSpec{}
	}
	assert cursor.id == ''
	_ := validate_provider_cli_launch('codex', 'plan') or { panic(err) }
}
