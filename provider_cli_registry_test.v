module main

fn test_provider_cli_registry_is_truthful() {
	registry := provider_cli_registry()
	assert registry.len == 4
	for spec in registry {
		assert spec.exec.len > 0
		assert spec.permission_modes.len > 0
		// Muse is registered but must stay unverified until its wire
		// protocol is measured; it must never look launchable.
		if spec.id == 'muse' {
			assert spec.protocol == 'unknown'
			assert !spec.session_resume_verified
			assert spec.usage_reporting == 'unknown'
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
	if _ := validate_provider_cli_launch('muse', 'ask') {
		panic('muse must refuse to launch: protocol unverified')
	}
	if _ := validate_provider_cli_launch('nope', 'ask') {
		panic('unknown provider must refuse to launch')
	}
	_ := validate_provider_cli_launch('codex', 'plan') or { panic(err) }
}
