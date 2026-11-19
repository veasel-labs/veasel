module main

import context as vcontext
import os
import time
import uuid

// #747: delegated child shell. Refusal shim tests run on any platform; the
// sandbox escape tests need Linux + bwrap + prlimit and skip otherwise.

fn test_delegated_child_shell_refuses_off_linux_and_without_backends() {
	for platform in ['macos', 'windows', 'other'] {
		msg := delegated_child_shell_refusal(platform, true, true) or {
			assert false, '${platform} must refuse'
			return
		}
		assert msg.contains('Linux')
		assert msg.contains('no process was started')
	}
	no_bwrap := delegated_child_shell_refusal('linux', false, true) or { '' }
	assert no_bwrap.contains(shell_sandbox_install_hint('linux'))
	no_prlimit := delegated_child_shell_refusal('linux', true, false) or { '' }
	assert no_prlimit.contains('prlimit')
	if _ := delegated_child_shell_refusal('linux', true, true) {
		assert false, 'linux with both backends must be allowed'
	}
}

fn test_delegated_child_shell_ignores_the_unsandboxed_opt_in() {
	// The explicit opt-in is for the parent's reviewed shell; it must never
	// widen a child. The refusal function takes no opt-in input at all.
	prior := os.getenv_opt(shell_sandbox_opt_in_env)
	os.setenv(shell_sandbox_opt_in_env, shell_unsandboxed_opt_in_token, true)
	defer {
		if v := prior {
			os.setenv(shell_sandbox_opt_in_env, v, true)
		} else {
			os.unsetenv(shell_sandbox_opt_in_env)
		}
	}
	assert delegated_child_shell_refusal('macos', true, true) != none
	assert delegated_child_shell_refusal('windows', true, true) != none
}

struct ChildShellLayout {
	base     string
	root     string // <data>/subagent-worktrees
	worktree string
	sibling  string
	outside  string
}

fn child_shell_layout() ?ChildShellLayout {
	$if !linux {
		return none
	}
	if !bubblewrap_available() || !prlimit_available() {
		return none
	}
	base := os.real_path(os.join_path(os.temp_dir(), 'veasel-child-shell-${uuid.new_v4().str()}'))
	root := os.join_path(base, 'subagent-worktrees')
	worktree := os.join_path(root, 'run-a')
	sibling := os.join_path(root, 'run-b')
	outside := os.join_path(base, 'outside')
	os.mkdir_all(worktree) or { panic(err) }
	os.mkdir_all(sibling) or { panic(err) }
	os.mkdir_all(outside) or { panic(err) }
	os.write_file(os.join_path(sibling, 'secret.txt'), 'sibling-safe') or { panic(err) }
	os.write_file(os.join_path(outside, 'secret.txt'), 'outside-safe') or { panic(err) }
	return ChildShellLayout{
		base:     base
		root:     root
		worktree: os.real_path(worktree)
		sibling:  os.real_path(sibling)
		outside:  os.real_path(outside)
	}
}

fn run_child_shell(layout ChildShellLayout, command string, cwd string) ShellCommandResult {
	mut background := vcontext.background()
	mut ctx, cancel := vcontext.with_timeout(mut background, 20 * time.second)
	defer { cancel() }
	return run_delegated_child_shell_command(mut ctx, layout.worktree, ShellCommandSummary{
		command:         command
		cwd:             cwd
		timeout_seconds: 5
	})
}

fn test_delegated_child_shell_runs_inside_worktree_only() {
	layout := child_shell_layout() or { return }
	defer { os.rmdir_all(layout.base) or {} }
	os.symlink(layout.outside, os.join_path(layout.worktree, 'link-out')) or { panic(err) }
	result := run_child_shell(layout,
		'printf ok > inside.txt; (printf bad > ${layout.sibling}/secret.txt) 2>/dev/null && exit 31; (printf bad > ${layout.outside}/secret.txt) 2>/dev/null && exit 32; (printf bad > link-out/secret.txt) 2>/dev/null && exit 33; (printf bad > ../run-b/secret.txt) 2>/dev/null && exit 34; cat /proc/net/dev | grep -v "^ *lo:" | grep -c ": " ; printf done',
		'.')
	assert result.output.contains('done'), result.output
	assert os.read_file(os.join_path(layout.worktree, 'inside.txt')) or { panic(err) } == 'ok'
	assert os.read_file(os.join_path(layout.sibling, 'secret.txt')) or { panic(err) } == 'sibling-safe'
	assert os.read_file(os.join_path(layout.outside, 'secret.txt')) or { panic(err) } == 'outside-safe'
	// Only loopback exists in the child's network namespace.
	assert result.output.trim_space().starts_with('0'), result.output
}

fn test_delegated_child_shell_rejects_cwd_escape_before_starting() {
	layout := child_shell_layout() or { return }
	defer { os.rmdir_all(layout.base) or {} }
	for cwd in ['..', '../run-b', layout.outside, 'link/../..'] {
		result := run_child_shell(layout, 'printf started > started.txt', cwd)
		assert result.status == 'failed', '${cwd}: ${result.output}'
		assert !os.exists(os.join_path(layout.worktree, 'started.txt'))
		assert !os.exists(os.join_path(layout.sibling, 'started.txt'))
	}
}

fn test_delegated_child_shell_has_resource_limits() {
	layout := child_shell_layout() or { return }
	defer { os.rmdir_all(layout.base) or {} }
	result := run_child_shell(layout, 'grep "Max processes" /proc/self/limits', '.')
	assert result.status == 'succeeded', result.output
	assert result.output.contains('256'), result.output
}

fn test_sealed_snapshot_syncs_changes_and_refuses_new_links() {
	$if !linux {
		return
	}
	layout := child_shell_layout() or { return }
	defer { os.rmdir_all(layout.base) or {} }
	os.write_file(os.join_path(layout.worktree, 'keep.txt'), 'keep') or { panic(err) }
	os.write_file(os.join_path(layout.worktree, 'gone.txt'), 'gone') or { panic(err) }
	sealed := seal_child_worktree_snapshot(layout.worktree) or { panic(err) }
	// Simulate command effects inside the sandbox: edit, create, delete, link.
	os.write_file(os.join_path(sealed.dir, 'keep.txt'), 'changed') or { panic(err) }
	os.write_file(os.join_path(sealed.dir, 'new.txt'), 'new') or { panic(err) }
	os.rm(os.join_path(sealed.dir, 'gone.txt')) or { panic(err) }
	sync := sync_sealed_snapshot_back(layout.worktree, sealed)
	assert sync.err == '', sync.err
	assert sync.changed == 3, '${sync.changed}'
	assert os.read_file(os.join_path(layout.worktree, 'keep.txt')) or { panic(err) } == 'changed'
	assert os.read_file(os.join_path(layout.worktree, 'new.txt')) or { panic(err) } == 'new'
	assert !os.exists(os.join_path(layout.worktree, 'gone.txt'))
	os.rmdir_all(sealed.dir) or {}
	// A link created by the command is refused and the snapshot preserved.
	sealed2 := seal_child_worktree_snapshot(layout.worktree) or { panic(err) }
	os.symlink(layout.outside, os.join_path(sealed2.dir, 'escape')) or { panic(err) }
	sync2 := sync_sealed_snapshot_back(layout.worktree, sealed2)
	assert sync2.err.contains('symbolic link'), sync2.err
	assert os.is_dir(sealed2.dir), 'refused snapshot must be preserved for review'
	os.rmdir_all(sealed2.dir) or {}
}

fn test_sealed_snapshot_breaks_hardlink_aliasing() {
	$if !linux {
		return
	}
	layout := child_shell_layout() or { return }
	defer { os.rmdir_all(layout.base) or {} }
	target := os.join_path(layout.worktree, 'shared.txt')
	os.write_file(target, 'original') or { panic(err) }
	os.link(target, os.join_path(layout.worktree, 'alias.txt')) or { panic(err) }
	sealed := seal_child_worktree_snapshot(layout.worktree) or { panic(err) }
	defer { os.rmdir_all(sealed.dir) or {} }
	os.write_file(os.join_path(sealed.dir, 'alias.txt'), 'snapshot-only') or { panic(err) }
	sync := sync_sealed_snapshot_back(layout.worktree, sealed)
	assert sync.err == '', sync.err
	// The snapshot copy is a fresh inode: writing it cannot alias outside
	// files, and sync-back writes each path as its own regular file.
	assert os.read_file(os.join_path(layout.worktree, 'alias.txt')) or { panic(err) } == 'snapshot-only'
	assert os.read_file(os.join_path(layout.worktree, 'shared.txt')) or { panic(err) } == 'original'
}

fn test_delegated_child_shell_syncs_command_changes_back() {
	layout := child_shell_layout() or { return }
	defer { os.rmdir_all(layout.base) or {} }
	os.write_file(os.join_path(layout.worktree, 'a.txt'), 'a') or { panic(err) }
	result := run_child_shell(layout, 'printf made > made.txt; rm a.txt; printf done', '.')
	assert result.status == 'succeeded', result.output
	assert result.output.contains('Sealed snapshot'), result.output
	assert os.read_file(os.join_path(layout.worktree, 'made.txt')) or { panic(err) } == 'made'
	assert !os.exists(os.join_path(layout.worktree, 'a.txt'))
}
