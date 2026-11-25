module main

import os
import time

// Shared lifecycle for installed-CLI child processes. Every CLI runner spawns
// its process in its own process group (use_pgroup) so a cancel, deadline or
// timeout can take down the CLI AND the tools it spawned, never leaving the
// user's permissions running after the turn ended.

// CliCancelFn reports why a CLI turn must stop ('cancelled' or
// 'deadline_exceeded'), or none while the turn may continue. A nil value never
// cancels.
pub type CliCancelFn = fn () ?string

const cli_process_term_grace = 300 * time.millisecond

fn cli_cancel_reason(cancel CliCancelFn) ?string {
	if cancel == unsafe { nil } {
		return none
	}
	return cancel()
}

// cli_terminate_process stops the CLI and its whole process group: SIGTERM,
// a bounded grace, SIGKILL to the group (descendants included), then reap. It
// is safe to call on an already-exited process.
fn cli_terminate_process(mut process os.Process) {
	$if windows {
		if process.is_alive() {
			process.signal_pgkill()
			process.wait()
		}
		process.close()
	} $else {
		if process.is_alive() {
			process.signal_term()
			deadline := time.now().add(cli_process_term_grace)
			for process.is_alive() && time.now() < deadline {
				time.sleep(10 * time.millisecond)
			}
		}
		// The leader may already have exited while descendants still run in
		// its group; the group id equals the leader pid (use_pgroup).
		cli_kill_process_group(process.pid)
		if process.is_alive() {
			process.signal_kill()
		}
		process.wait()
		process.close()
	}
}

// The native agent may log warnings to its separate pipe before writing a
// protocol response. Leave the bytes out of the journal and keep draining so
// that a full stderr pipe cannot block protocol and cancellation progress.
fn discard_cli_stderr(mut process os.Process) {
	_ = process.stderr_read()
}
