module main

import context as vcontext
import os
import time
import uuid

fn test_approved_shell_sandbox_mode_parses_known_values() {
	assert approved_shell_sandbox_mode_from('') == .require
	assert approved_shell_sandbox_mode_from('auto') == .auto
	assert approved_shell_sandbox_mode_from('OFF') == .off
	assert approved_shell_sandbox_mode_from('require') == .require
	assert approved_shell_sandbox_mode_from('strict') == .require
	assert approved_shell_sandbox_mode_from('unknown-value') == .require
	assert approved_shell_sandbox_mode_label(.off) == 'off'
	assert approved_shell_sandbox_mode_label(.auto) == 'auto'
	assert approved_shell_sandbox_mode_label(.require) == 'require'
}

fn test_approved_shell_sandbox_defaults_to_fail_closed() {
	previous := os.getenv_opt(shell_sandbox_mode_env)
	defer {
		if value := previous {
			os.setenv(shell_sandbox_mode_env, value, true)
		} else {
			os.unsetenv(shell_sandbox_mode_env)
		}
	}
	os.unsetenv(shell_sandbox_mode_env)
	assert approved_shell_sandbox_mode() == .require
}

fn test_shell_review_sandbox_preview_matches_capabilities() {
	previous := os.getenv(shell_sandbox_mode_env)
	defer {
		if previous.len > 0 {
			os.setenv(shell_sandbox_mode_env, previous, true)
		} else {
			os.unsetenv(shell_sandbox_mode_env)
		}
	}
	previous_network := os.getenv(shell_sandbox_network_env)
	defer {
		if previous_network.len > 0 {
			os.setenv(shell_sandbox_network_env, previous_network, true)
		} else {
			os.unsetenv(shell_sandbox_network_env)
		}
	}
	os.unsetenv(shell_sandbox_network_env)
	os.setenv(shell_sandbox_mode_env, 'off', true)
	off := shell_review_sandbox_preview()
	assert off.mode == 'off'
	assert !off.will_wrap
	assert off.backend == 'none'
	assert off.network == 'host'
	os.setenv(shell_sandbox_mode_env, 'auto', true)
	preview := shell_review_sandbox_preview()
	assert preview.mode == 'auto'
	if shell_sandbox_bubblewrap_capability() {
		assert preview.will_wrap
		assert preview.backend == 'bubblewrap'
		assert preview.network == 'deny'
	} else if shell_sandbox_seatbelt_capability() {
		assert preview.will_wrap
		assert preview.backend == 'seatbelt'
		assert preview.network == 'deny'
	} else if shell_sandbox_windows_capability() {
		assert preview.will_wrap
		assert preview.backend == 'windows'
		assert preview.network == 'deny'
	} else {
		assert !preview.will_wrap
		assert preview.backend == 'none'
		assert preview.network == 'host'
	}
	os.setenv(shell_sandbox_network_env, 'allow', true)
	allowed := shell_review_sandbox_preview()
	if allowed.will_wrap {
		assert allowed.network == 'allow'
	} else {
		assert allowed.network == 'host'
	}
}

fn test_approved_shell_sandbox_network_flag_parses_allowlist() {
	assert !approved_shell_sandbox_network_allowed_from('')
	assert !approved_shell_sandbox_network_allowed_from('deny')
	assert approved_shell_sandbox_network_allowed_from('allow')
	assert approved_shell_sandbox_network_allowed_from('YES')
}

fn test_linux_shell_writable_scope_rejects_parent_escape_and_symlinks() {
	$if !linux {
		return
	}
	root := os.join_path(os.temp_dir(), 'veasel-write-scope-${uuid.new_v4().str()}')
	child := os.join_path(root, 'child')
	sibling := os.join_path(root, 'sibling')
	external := '${root}-external'
	os.mkdir_all(child) or { panic(err) }
	os.mkdir_all(sibling) or { panic(err) }
	os.mkdir_all(external) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
		os.rmdir_all(external) or {}
	}
	canonical_root := os.real_path(root)
	canonical_child := os.real_path(child)
	assert validate_linux_shell_writable_scope(canonical_root, canonical_child) or { panic(err) } == canonical_child
	assert linux_shell_writable_scope_rejected(canonical_root, canonical_root)
	assert linux_shell_writable_scope_rejected(canonical_root, external)
	assert linux_shell_writable_scope_rejected(canonical_root, os.temp_dir())
	link := os.join_path(child, 'escape')
	os.symlink(sibling, link) or { panic(err) }
	assert linux_shell_writable_scope_rejected(canonical_root, link)
}

fn test_linux_bubblewrap_default_scope_rejects_symlink_to_broad_root() {
	$if !linux {
		return
	}
	link := os.join_path(os.temp_dir(), 'veasel-broad-root-${uuid.new_v4().str()}')
	os.symlink('/home', link) or { panic(err) }
	defer { os.rm(link) or {} }
	mut background := vcontext.background()
	mut turn_ctx, cancel := vcontext.with_timeout(mut background, 5 * time.second)
	defer { cancel() }
	result := run_linux_sandboxed_shell_command(mut turn_ctx, link, '.', ShellCommandSummary{
		command:         'printf unsafe-root-command-started'
		cwd:             '.'
		timeout_seconds: 2
	}, LinuxShellSandboxOptions{
		purpose:            'Delegated child command'
		fail_closed:        true
		filter_environment: true
		allow_network:      false
	})
	assert result.status == 'failed'
	assert result.output.contains('symbolic-link workspace root')
	assert !result.output.contains('unsafe-root-command-started')
}

fn linux_shell_writable_scope_rejected(root string, writable_root string) bool {
	_ := validate_linux_shell_writable_scope(root, writable_root) or { return true }
	return false
}

fn test_linux_bubblewrap_child_write_scope_keeps_parent_and_sibling_read_only() {
	$if !linux {
		return
	}
	if !bubblewrap_available() || !os.is_dir('/var/tmp') {
		return
	}
	parent := os.join_path('/var/tmp', 'veasel-child-sandbox-${uuid.new_v4().str()}')
	root := os.join_path(parent, 'parent-workspace')
	child := os.join_path(root, 'child-worktree')
	sibling := os.join_path(root, 'sibling-worktree')
	os.mkdir_all(child) or { panic(err) }
	os.mkdir_all(sibling) or { panic(err) }
	defer { os.rmdir_all(parent) or {} }
	protected_parent_file := os.join_path(root, 'parent.txt')
	protected_sibling_file := os.join_path(sibling, 'sibling.txt')
	os.write_file(protected_parent_file, 'parent-safe') or { panic(err) }
	os.write_file(protected_sibling_file, 'sibling-safe') or { panic(err) }
	os.symlink(sibling, os.join_path(child, 'escape')) or { panic(err) }
	canonical_root := os.real_path(root)
	canonical_child := os.real_path(child)
	command := 'printf child-ok > result.txt; if printf bad > "${protected_parent_file}" 2>/dev/null; then exit 31; fi; if printf bad > "${protected_sibling_file}" 2>/dev/null; then exit 32; fi; if printf bad > escape/sibling.txt 2>/dev/null; then exit 33; fi; if test -e /run/user; then exit 34; fi; printf scoped-ok'
	mut background := vcontext.background()
	mut turn_ctx, cancel := vcontext.with_timeout(mut background, 10 * time.second)
	defer { cancel() }
	result := run_linux_sandboxed_shell_command_with_write_scope(mut turn_ctx, canonical_root,
		'child-worktree', ShellCommandSummary{
			command:         command
			cwd:             'child-worktree'
			timeout_seconds: 5
		}, LinuxShellSandboxOptions{
			purpose:            'Delegated child command'
			fail_closed:        true
			filter_environment: true
			allow_network:      false
		}, canonical_child)
	assert result.status == 'succeeded', result.output
	assert result.output.contains('scoped-ok')
	assert os.read_file(os.join_path(child, 'result.txt')) or { panic(err) } == 'child-ok'
	assert os.read_file(protected_parent_file) or { panic(err) } == 'parent-safe'
	assert os.read_file(protected_sibling_file) or { panic(err) } == 'sibling-safe'
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

fn test_shell_sandbox_windows_capability_is_platform_honest() {
	$if windows {
		previous := os.getenv(shell_sandbox_mode_env)
		defer {
			if previous.len == 0 {
				os.unsetenv(shell_sandbox_mode_env)
			} else {
				os.setenv(shell_sandbox_mode_env, previous, true)
			}
		}
		os.setenv(shell_sandbox_mode_env, 'off', true)
		assert !shell_sandbox_windows_capability()
		os.setenv(shell_sandbox_mode_env, 'auto', true)
		assert shell_sandbox_windows_capability() == windows_appcontainer_sandbox_available()
	} $else {
		assert !shell_sandbox_windows_capability()
	}
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
	os.unsetenv(shell_sandbox_mode_env)
	os.unsetenv(shell_sandbox_network_env)
	assert shell_sandbox_bubblewrap_capability()

	parent := os.join_path(os.temp_dir(), 'veasel-approved-sandbox-${uuid.new_v4().str()}')
	raw_root := os.join_path(parent, 'workspace')
	os.mkdir_all(parent) or { panic(err) }
	os.mkdir_all(raw_root) or { panic(err) }
	defer { os.rmdir_all(parent) or {} }
	root := canonical_workspace_root(raw_root) or { panic(err) }
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
	os.unsetenv(shell_sandbox_mode_env)
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
	os.unsetenv(shell_sandbox_mode_env)
	os.unsetenv(shell_sandbox_network_env)
	assert shell_sandbox_seatbelt_capability()

	parent := os.join_path(os.temp_dir(), 'veasel-approved-seatbelt-${uuid.new_v4().str()}')
	raw_root := os.join_path(parent, 'workspace')
	os.mkdir_all(parent) or { panic(err) }
	os.mkdir_all(raw_root) or { panic(err) }
	defer { os.rmdir_all(parent) or {} }
	root := canonical_workspace_root(raw_root) or { panic(err) }

	result := run_approved_shell_command(root, ShellCommandSummary{
		command:         'touch sandbox-write.txt; printf approved-seatbelt-ok'
		cwd:             '.'
		timeout_seconds: 5
	})
	assert result.status == 'succeeded', result.output
	assert result.output.contains('approved-seatbelt-ok')
	assert os.is_file(os.join_path(root, 'sandbox-write.txt'))
}

fn test_approved_shell_uses_windows_appcontainer_sandbox_when_available() {
	$if !windows {
		return
	}
	if !windows_appcontainer_sandbox_available() {
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
	os.unsetenv(shell_sandbox_mode_env)
	os.unsetenv(shell_sandbox_network_env)
	assert shell_sandbox_windows_capability()

	parent := os.join_path(os.temp_dir(), 'veasel-approved-windows-ac-${uuid.new_v4().str()}')
	raw_root := os.join_path(parent, 'workspace')
	outside := os.join_path(parent, 'outside')
	os.mkdir_all(parent) or { panic(err) }
	os.mkdir_all(raw_root) or { panic(err) }
	os.mkdir_all(outside) or { panic(err) }
	defer { os.rmdir_all(parent) or {} }
	root := canonical_workspace_root(raw_root) or { panic(err) }
	secret_env_name := 'VEASEL_TEST_INHERITED_SECRET'
	previous_secret := os.getenv(secret_env_name)
	os.setenv(secret_env_name, 'must-not-reach-child', true)
	defer {
		if previous_secret.len == 0 {
			os.unsetenv(secret_env_name)
		} else {
			os.setenv(secret_env_name, previous_secret, true)
		}
	}

	// Prefer workspace-file side effects over stdout: AppContainer stdio pipe
	// capture is unreliable on some hosts even when the command succeeds. Also
	// prove the child does not inherit an unrelated parent-process secret.
	result := run_approved_shell_command(root, ShellCommandSummary{
		command:         'echo approved-windows-ac-ok>sandbox-write.txt & if defined ${secret_env_name} (echo inherited>sandbox-env.txt) else (echo filtered>sandbox-env.txt)'
		cwd:             '.'
		timeout_seconds: 5
	})
	assert result.status == 'succeeded', result.output
	written := os.read_file(os.join_path(root, 'sandbox-write.txt')) or { '' }
	assert written.contains('approved-windows-ac-ok'), written
	environment_result := os.read_file(os.join_path(root, 'sandbox-env.txt')) or { '' }
	assert environment_result.contains('filtered'), environment_result
	assert !environment_result.contains('inherited'), environment_result

	// Sibling path is not ACL-granted; AppContainer write must fail.
	denied := run_approved_shell_command(root, ShellCommandSummary{
		command:         'echo leak>..\\outside\\leak.txt'
		cwd:             '.'
		timeout_seconds: 5
	})
	assert denied.status == 'failed', denied.output
	assert !os.is_file(os.join_path(outside, 'leak.txt'))
}

fn test_approved_shell_windows_appcontainer_denies_network_by_default() {
	$if !windows {
		return
	}
	if !windows_appcontainer_sandbox_available() {
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
	os.unsetenv(shell_sandbox_mode_env)
	os.unsetenv(shell_sandbox_network_env)

	root := os.join_path(os.temp_dir(), 'veasel-approved-windows-net-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }

	// curl.exe is on PATH for Windows runners; without internetClient capability
	// the connect should fail and the || branch records NET_BLOCKED in-workspace.
	result := run_approved_shell_command(root, ShellCommandSummary{
		command:         'curl.exe -s -m 2 -o NUL http://1.1.1.1 && echo NET_OPEN>net-result.txt || echo NET_BLOCKED>net-result.txt'
		cwd:             '.'
		timeout_seconds: 10
	})
	assert result.status == 'succeeded', result.output
	net_result := os.read_file(os.join_path(root, 'net-result.txt')) or { '' }
	assert net_result.contains('NET_BLOCKED'), net_result
	assert !net_result.contains('NET_OPEN'), net_result
}

fn test_approved_shell_require_mode_uses_windows_appcontainer_or_fails_closed() {
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
	if windows_appcontainer_sandbox_available() {
		assert shell_sandbox_windows_capability()
		root := os.join_path(os.temp_dir(), 'veasel-approved-windows-require-ok-${uuid.new_v4().str()}')
		os.mkdir_all(root) or { panic(err) }
		defer { os.rmdir_all(root) or {} }
		result := run_approved_shell_command(root, ShellCommandSummary{
			command:         'echo require-windows-ac-ok>require-ok.txt'
			cwd:             '.'
			timeout_seconds: 5
		})
		assert result.status == 'succeeded', result.output
		written := os.read_file(os.join_path(root, 'require-ok.txt')) or { '' }
		assert written.contains('require-windows-ac-ok'), written
		return
	}
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
	assert result.output.contains('requires a Windows AppContainer sandbox')
	assert !result.output.contains('must-not-run')
}

fn test_shell_command_with_cancelled_context_never_starts() {
	root := os.join_path(os.temp_dir(), 'veasel-shell-pre-cancelled-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut background := vcontext.background()
	mut turn_ctx, cancel := vcontext.with_cancel(mut background)
	cancel()
	result := run_approved_shell_command_with_context(mut turn_ctx, root, ShellCommandSummary{
		command:         'echo must-not-run > cancelled-effect.txt'
		cwd:             '.'
		timeout_seconds: 5
	}, true)
	assert result.status == 'cancelled', result.output
	assert !os.exists(os.join_path(root, 'cancelled-effect.txt'))
}

// Isolation for the C bridge: a flag already set before the call must
// terminate the job as cancelled, without the watcher involved.
fn test_windows_sandbox_runner_honors_preset_cancel_flag() {
	$if windows {
		if !windows_appcontainer_sandbox_available() {
			return
		}
		root := os.join_path(os.temp_dir(), 'veasel-shell-preset-cancel-${uuid.new_v4().str()}')
		os.mkdir_all(root) or { panic(err) }
		defer { os.rmdir_all(root) or {} }
		shell := os.getenv('COMSPEC')
		assert shell.len > 0
		env_block := windows_mcp_env_block(autonomous_shell_environment())
		mut cancel_flag := 1
		mut result := C.VeaselWinSandboxResult{}
		ok := C.veasel_win_run_sandboxed_shell_ex(shell.str,
			c'for /L %i in (1,1,200000000) do @rem veasel-cancel-spin', root.str,
			env_block.str, 30000, max_shell_command_output_bytes, 0, &cancel_flag, &result)
		defer { C.veasel_win_sandbox_result_free(&result) }
		assert ok != 0 && result.setup_failed == 0, 'sandboxed runner failed to start'
		assert result.cancelled != 0, 'preset cancel flag ignored (timed_out=${result.timed_out} exit=${result.exit_code})'
	}
}

fn test_shell_command_cancelled_mid_run_kills_process_group() {
	$if windows {
		if !windows_appcontainer_sandbox_available() {
			return
		}
	}
	root := os.join_path(os.temp_dir(), 'veasel-shell-mid-cancel-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut background := vcontext.background()
	mut turn_ctx, cancel := vcontext.with_cancel(mut background)
	// Windows: cmd has no sleep builtin, loopback ping is unavailable
	// inside the AppContainer, and PowerShell dies on the filtered
	// environment, so burn time in a pure-cmd loop that only writes
	// the effect file if it ever finishes (it cannot: the iteration
	// count holds it far past the 30s command timeout).
	mut command := 'sleep 5 && echo cancel-survived > cancelled-effect.txt'
	mut cancel_after := 400 * time.millisecond
	mut elapsed_limit := u64(4000)
	$if windows {
		command = 'for /L %i in (1,1,200000000) do @rem veasel-cancel-spin & echo cancel-survived > cancelled-effect.txt'
		cancel_after = 2500 * time.millisecond
		elapsed_limit = 9000
	}
	spawn fn (cancel vcontext.CancelFn, delay time.Duration) {
		time.sleep(delay)
		cancel()
	}(cancel, cancel_after)
	started := time.sys_mono_now()
	result := run_approved_shell_command_with_context(mut turn_ctx, root, ShellCommandSummary{
		command:         command
		cwd:             '.'
		timeout_seconds: 30
	}, true)
	elapsed_ms := (time.sys_mono_now() - started) / time.millisecond
	assert result.status == 'cancelled', result.output
	assert elapsed_ms < elapsed_limit
	// Give a leaked process group time to betray itself after the sleep.
	time.sleep(300 * time.millisecond)
	assert !os.exists(os.join_path(root, 'cancelled-effect.txt'))
}

fn test_macos_seatbelt_profile_denies_network_by_default() {
	denied := macos_seatbelt_profile(false)
	assert denied.contains('(deny default)')
	assert denied.contains('(param "WORKSPACE")')
	assert !denied.contains('(allow network-outbound)')
	allowed := macos_seatbelt_profile(true)
	assert allowed.contains('(allow network-outbound)')
}
