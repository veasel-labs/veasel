module main

// Platform shim tests (#748): assert on Linux CI that every sandbox/confinement
// path that cannot be validated off Linux refuses instead of silently
// degrading. They exercise pure decision functions, not macOS/Windows runtimes.

fn test_every_platform_without_a_backend_refuses_approved_shell() {
	for platform in ['macos', 'windows', 'other'] {
		for mode in [ApprovedShellSandboxMode.auto, .off, .require] {
			assert approved_shell_sandbox_plan(mode, false, false) == .refuse
		}
		message := approved_shell_sandbox_refusal(platform)
		assert message.contains('No process') || message.contains('no process')
		assert message.contains(shell_sandbox_install_hint(platform))
	}
}

fn test_platforms_other_than_linux_refuse_delegated_child_shell_even_with_backends() {
	for platform in ['macos', 'windows', 'other'] {
		reason := delegated_child_shell_refusal(platform, true, true) or { '' }
		assert reason.contains('only available on Linux'), platform
	}
}

fn test_unsandboxed_opt_in_never_changes_a_refusal_for_require() {
	assert approved_shell_sandbox_plan(.require, false, true) == .refuse
}
