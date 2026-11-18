module main

import context as vcontext
import os

// Delegated child shell (#747). A shell command in a child (subagent) session
// never uses the ordinary approved-shell path: it runs only through the Linux
// Bubblewrap child sandbox (network denied, writable scope narrowed to the
// child worktree, prlimit limits) and is refused on every other platform. The
// parent's explicit unsandboxed opt-in is deliberately NOT consulted here, so a
// child can never be widened beyond the sandbox.

fn current_platform_name() string {
	return $if linux {
		'linux'
	} $else $if macos {
		'macos'
	} $else $if windows {
		'windows'
	} $else {
		'other'
	}
}

// delegated_child_shell_refusal returns the reason a delegated child command
// must not start, or none when every required backend is present. It is a pure
// function of its inputs so platform refusals are testable on Linux CI.
fn delegated_child_shell_refusal(platform string, bwrap_available bool, prlimit_available bool) ?string {
	if platform != 'linux' {
		return 'Delegated child shell execution is only available on Linux (Bubblewrap + prlimit); this platform has no child sandbox, so no process was started.'
	}
	if !bwrap_available {
		return 'Delegated child shell execution requires Bubblewrap (${shell_sandbox_install_hint('linux')}); no process was started.'
	}
	if !prlimit_available {
		return 'Delegated child shell execution requires prlimit from util-linux for its resource limits; no process was started.'
	}
	return none
}

fn prlimit_available() bool {
	os.find_abs_path_of_executable('prlimit') or { return false }
	return true
}

// run_delegated_child_shell_command runs command inside the child worktree
// through the fail-closed child sandbox. worktree must be the canonical child
// worktree directory (<data>/subagent-worktrees/<run id>).
fn run_delegated_child_shell_command(mut turn_ctx vcontext.Context, worktree string,
	command ShellCommandSummary) ShellCommandResult {
	if reason := delegated_child_shell_refusal(current_platform_name(), bubblewrap_available(),
		prlimit_available())
	{
		return ShellCommandResult{
			status:    'failed'
			exit_code: -1
			output:    reason
		}
	}
	canonical := os.real_path(worktree)
	if canonical != worktree || os.is_link(worktree) || !os.is_dir(worktree) {
		return ShellCommandResult{
			status:    'failed'
			exit_code: -1
			output:    'Delegated child shell refused a non-canonical child worktree; no process was started.'
		}
	}
	draft := prepare_shell_command(canonical, command.command, command.cwd, command.timeout_seconds) or {
		return ShellCommandResult{
			status:    'failed'
			exit_code: -1
			output:    'Delegated child shell refused the command or working directory: ${err.msg()}; no process was started.'
		}
	}
	run_dir := os.file_name(canonical)
	cwd := if draft.cwd == '.' { run_dir } else { os.join_path(run_dir, draft.cwd) }
	return run_linux_sandboxed_shell_command_with_write_scope(mut turn_ctx, os.dir(canonical),
		cwd, ShellCommandSummary{
			id:              command.id
			command:         draft.command
			cwd:             cwd
			timeout_seconds: draft.timeout_seconds
		}, LinuxShellSandboxOptions{
			purpose:            'Delegated child command'
			fail_closed:        true
			filter_environment: true
			allow_network:      false
			limit_resources:    true
		}, canonical)
}

// child_subagent_run_id returns the subagent run whose child session is
// session_id, or '' for an ordinary session. A lookup failure is an error so
// callers fail closed instead of treating a child as an ordinary session.
fn (mut store Store) child_subagent_run_id(session_id string) !string {
	store.mu.lock()
	defer { store.mu.unlock() }
	rows := store.db.exec_param_many('SELECT id FROM subagent_runs WHERE child_session_id = ? LIMIT 1',
		[session_id])!
	if rows.len == 0 {
		return ''
	}
	return rows[0].val(0)
}

// run_session_shell_command is the single execution choke point for approved
// shell commands: child sessions are routed to the child sandbox, everything
// else keeps the ordinary approved/autonomous behaviour.
fn (app &App) run_session_shell_command(mut turn_ctx vcontext.Context, session_id string, root string,
	command ShellCommandSummary, sanitize_environment bool) ShellCommandResult {
	mut store := app.store
	run_id := store.child_subagent_run_id(session_id) or {
		return ShellCommandResult{
			status:    'failed'
			exit_code: -1
			output:    'Unable to determine whether this session is a delegated child; no process was started.'
		}
	}
	if run_id.len == 0 {
		return run_approved_shell_command_with_context(mut turn_ctx, root, command, sanitize_environment)
	}
	expected := os.join_path(os.dir(os.real_path(store.path)), 'subagent-worktrees', run_id)
	if !os.is_dir(expected) || os.real_path(root) != os.real_path(expected) {
		return ShellCommandResult{
			status:    'failed'
			exit_code: -1
			output:    'The child workspace is unavailable or no longer matches its durable run; no process was started.'
		}
	}
	return run_delegated_child_shell_command(mut turn_ctx, os.real_path(expected), command)
}
