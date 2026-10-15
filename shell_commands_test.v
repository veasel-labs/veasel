module main

import os
import uuid

fn test_approved_shell_sandbox_mode_parses_known_values() {
	assert approved_shell_sandbox_mode_from('') == .auto
	assert approved_shell_sandbox_mode_from('auto') == .auto
	assert approved_shell_sandbox_mode_from('OFF') == .off
	assert approved_shell_sandbox_mode_from('require') == .require
	assert approved_shell_sandbox_mode_from('strict') == .require
	assert approved_shell_sandbox_mode_from('unknown-value') == .auto
}

fn test_approved_shell_sandbox_network_flag_parses_allowlist() {
	assert !approved_shell_sandbox_network_allowed_from('')
	assert !approved_shell_sandbox_network_allowed_from('deny')
	assert approved_shell_sandbox_network_allowed_from('allow')
	assert approved_shell_sandbox_network_allowed_from('YES')
}

fn test_shell_sandbox_bubblewrap_capability_is_false_when_disabled() {
	$if linux {
		previous := os.getenv(shell_sandbox_mode_env)
		defer {
			if previous.len == 0 {
				os.unsetenv(shell_sandbox_mode_env)
			} else {
				os.setenv(shell_sandbox_mode_env, previous, true)
			}
		}
		os.setenv(shell_sandbox_mode_env, 'off', true)
		assert !shell_sandbox_bubblewrap_capability()
	} $else {
		assert !shell_sandbox_bubblewrap_capability()
	}
}

fn test_shell_sandbox_seatbelt_capability_is_platform_honest() {
	$if macos {
		previous := os.getenv(shell_sandbox_mode_env)
		defer {
			if previous.len == 0 {
				os.unsetenv(shell_sandbox_mode_env)
			} else {
				os.setenv(shell_sandbox_mode_env, previous, true)
			}
		}
		os.setenv(shell_sandbox_mode_env, 'off', true)
		assert !shell_sandbox_seatbelt_capability()
		os.setenv(shell_sandbox_mode_env, 'auto', true)
		assert shell_sandbox_seatbelt_capability() == seatbelt_available()
	} $else {
		assert !shell_sandbox_seatbelt_capability()
		assert !seatbelt_available()
	}
}

fn test_shell_sandbox_windows_capability_is_never_advertised_yet() {
	assert !shell_sandbox_windows_capability()
}

fn test_approved_shell_uses_bubblewrap_when_available() {
	$if !linux {
		return
	}
	if !bubblewrap_available() {
		return
	}
	previous_mode := os.getenv(shell_sandbox_mode_env)
	previous_network := os.getenv(shell_sandbox_network_env)
	defer {
		if previous_mode.len == 0 {
			os.unsetenv(shell_sandbox_mode_env)
		} else {
			os.setenv(shell_sandbox_mode_env, previous_mode, true)
		}
		if previous_network.len == 0 {
			os.unsetenv(shell_sandbox_network_env)
		} else {
			os.setenv(shell_sandbox_network_env, previous_network, true)
		}
	}
	os.setenv(shell_sandbox_mode_env, 'auto', true)
	os.unsetenv(shell_sandbox_network_env)
	assert shell_sandbox_bubblewrap_capability()

	parent := os.join_path(os.temp_dir(), 'veasel-approved-sandbox-${uuid.new_v4().str()}')
	root := os.join_path(parent, 'workspace')
	os.mkdir_all(parent) or { panic(err) }
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(parent) or {} }
	outside_secret := os.join_path(parent, 'outside-secret.txt')
	os.write_file(outside_secret, 'must stay hidden') or { panic(err) }

	result := run_approved_shell_command(root, ShellCommandSummary{
		command:         'touch sandbox-write.txt; test ! -e "${outside_secret}"; test ! -e /run/user; printf approved-sandbox-ok'
		cwd:             '.'
		timeout_seconds: 5
	})
	assert result.status == 'succeeded', result.output
	assert result.output.contains('approved-sandbox-ok')
	assert os.is_file(os.join_path(root, 'sandbox-write.txt'))
	assert os.read_file(outside_secret) or { panic(err) } == 'must stay hidden'
}

fn test_approved_shell_require_mode_fails_closed_without_pretending_success() {
	$if !linux {
		return
	}
	previous := os.getenv(shell_sandbox_mode_env)
	defer {
		if previous.len == 0 {
			os.unsetenv(shell_sandbox_mode_env)
		} else {
			os.setenv(shell_sandbox_mode_env, previous, true)
		}
	}
	os.setenv(shell_sandbox_mode_env, 'require', true)
	if bubblewrap_available() {
		assert shell_sandbox_bubblewrap_capability()
		return
	}
	root := os.join_path(os.temp_dir(), 'veasel-approved-require-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	result := run_approved_shell_command(root, ShellCommandSummary{
		command:         'printf must-not-run'
		cwd:             '.'
		timeout_seconds: 5
	})
	assert result.status == 'failed'
	assert result.output.contains('requires bubblewrap')
	assert !result.output.contains('must-not-run')
}

fn test_approved_shell_uses_seatbelt_when_available() {
	$if !macos {
		return
	}
	if !seatbelt_available() {
		return
	}
	previous_mode := os.getenv(shell_sandbox_mode_env)
	previous_network := os.getenv(shell_sandbox_network_env)
	defer {
		if previous_mode.len == 0 {
			os.unsetenv(shell_sandbox_mode_env)
		} else {
			os.setenv(shell_sandbox_mode_env, previous_mode, true)
		}
		if previous_network.len == 0 {
			os.unsetenv(shell_sandbox_network_env)
		} else {
			os.setenv(shell_sandbox_network_env, previous_network, true)
		}
	}
	os.setenv(shell_sandbox_mode_env, 'auto', true)
	os.unsetenv(shell_sandbox_network_env)
	assert shell_sandbox_seatbelt_capability()

	parent := os.join_path(os.temp_dir(), 'veasel-approved-seatbelt-${uuid.new_v4().str()}')
	root := os.join_path(parent, 'workspace')
	os.mkdir_all(parent) or { panic(err) }
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(parent) or {} }

	result := run_approved_shell_command(root, ShellCommandSummary{
		command:         'touch sandbox-write.txt; printf approved-seatbelt-ok'
		cwd:             '.'
		timeout_seconds: 5
	})
	assert result.status == 'succeeded', result.output
	assert result.output.contains('approved-seatbelt-ok')
	assert os.is_file(os.join_path(root, 'sandbox-write.txt'))
}

fn test_approved_shell_require_mode_fails_closed_on_windows_without_fake_capability() {
	$if !windows {
		return
	}
	previous := os.getenv(shell_sandbox_mode_env)
	defer {
		if previous.len == 0 {
			os.unsetenv(shell_sandbox_mode_env)
		} else {
			os.setenv(shell_sandbox_mode_env, previous, true)
		}
	}
	os.setenv(shell_sandbox_mode_env, 'require', true)
	assert !shell_sandbox_windows_capability()
	root := os.join_path(os.temp_dir(), 'veasel-approved-windows-require-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	result := run_approved_shell_command(root, ShellCommandSummary{
		command:         'echo must-not-run'
		cwd:             '.'
		timeout_seconds: 5
	})
	assert result.status == 'failed'
	assert result.output.contains('requires a Windows OS sandbox')
	assert !result.output.contains('must-not-run')
}

fn test_macos_seatbelt_profile_denies_network_by_default() {
	denied := macos_seatbelt_profile(false)
	assert denied.contains('(deny default)')
	assert denied.contains('(param "WORKSPACE")')
	assert !denied.contains('(allow network-outbound)')
	allowed := macos_seatbelt_profile(true)
	assert allowed.contains('(allow network-outbound)')
}
