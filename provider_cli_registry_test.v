module main

fn test_provider_cli_registry_is_truthful() {
	registry := provider_cli_registry()
	assert registry.len == 4
	for spec in registry {
		assert spec.exec.len > 0
		assert spec.permission_modes.len > 0
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
	_ := validate_provider_cli_launch('codex', 'plan') or { panic(err) }
}
