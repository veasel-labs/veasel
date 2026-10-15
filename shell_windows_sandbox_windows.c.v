module main

import encoding.utf8
import os

#flag windows -ladvapi32
#flag windows -luserenv
#flag windows @VMODROOT/shell_windows_sandbox.c
#include "@VMODROOT/shell_windows_sandbox.h"

struct C.VeaselWinSandboxResult {
	ok                int
	setup_failed      int
	timed_out         int
	output_limited    int
	exit_code         int
	used_appcontainer int
	used_job_object   int
	output_len        int
	output            &char
	error_message     [512]char
}

fn C.veasel_win_sandbox_available() int
fn C.veasel_win_run_sandboxed_shell(comspec_utf8 &char, command_utf8 &char, workdir_utf8 &char,
	timeout_ms int, max_output_bytes int, allow_network int, result &C.VeaselWinSandboxResult) int
fn C.veasel_win_sandbox_result_free(result &C.VeaselWinSandboxResult)

fn windows_appcontainer_backend_available() bool {
	return C.veasel_win_sandbox_available() != 0
}

struct WindowsShellSandboxOptions {
	purpose       string
	fail_closed   bool
	allow_network bool
}

// Windows AppContainer + Job Object policy for approved shell (principles adapted
// from Codex Windows sandbox study; no upstream source copied):
// - AppContainer profile with workspace ACL grant (sibling paths stay denied)
// - network denied unless allow_network adds internetClient capability SIDs
// - Job Object: KILL_ON_JOB_CLOSE, active-process cap, job memory cap
// - CREATE_SUSPENDED then AssignProcessToJobObject before ResumeThread
// - inherited environment may still carry credentials; not a VM
fn run_windows_sandboxed_shell_command(root string, cwd string, command ShellCommandSummary,
	options WindowsShellSandboxOptions) ShellCommandResult {
	purpose := if options.purpose.len == 0 { 'Shell execution' } else { options.purpose }
	normalized := root.trim_right('\\/').to_lower()
	for broad_root in ['c:', 'c:\\windows', 'c:\\users', 'c:\\program files', 'c:\\program files (x86)',
		'c:\\programdata'] {
		if normalized == broad_root {
			return ShellCommandResult{
				status:    'failed'
				exit_code: -1
				output:    '${purpose} refused: the workspace root is too broad for the enforced sandbox.'
			}
		}
	}
	if !windows_appcontainer_backend_available() {
		if options.fail_closed {
			return ShellCommandResult{
				status:    'failed'
				exit_code: -1
				output:    '${purpose} requires a Windows AppContainer sandbox; no unsandboxed fallback was started.'
			}
		}
		return ShellCommandResult{
			status:    'failed'
			exit_code: -1
			output:    '${purpose} could not create a Windows AppContainer; no process was started.'
		}
	}
	shell := os.getenv('COMSPEC')
	if shell.len == 0 {
		return ShellCommandResult{
			status:    'failed'
			exit_code: -1
			output:    'COMSPEC is not configured'
		}
	}
	workdir := os.join_path(root, cwd)
	mut result := C.VeaselWinSandboxResult{}
	ok := C.veasel_win_run_sandboxed_shell(shell.str, command.command.str, workdir.str,
		command.timeout_seconds * 1000, max_shell_command_output_bytes, if options.allow_network {
			1
		} else {
			0
		}, &result)
	defer {
		C.veasel_win_sandbox_result_free(&result)
	}
	if ok == 0 || result.setup_failed != 0 {
		mut message := unsafe { cstring_to_vstring(&char(&result.error_message[0])) }
		if message.len == 0 {
			message = '${purpose} failed to start inside a Windows AppContainer; no unsandboxed fallback was started.'
		}
		return ShellCommandResult{
			status:    'failed'
			exit_code: -1
			output:    message
		}
	}
	mut safe_output := ''
	if result.output != unsafe { nil } && result.output_len > 0 {
		safe_output = unsafe { result.output.vstring_with_len(result.output_len) }
		bytes := safe_output.bytes()
		if !utf8.validate(&bytes[0], bytes.len) {
			safe_output = '[Output omitted: command produced invalid UTF-8]'
		}
	}
	if result.output_limited != 0 {
		safe_output += shell_output_limited_marker
	}
	status := if result.timed_out != 0 {
		'timed_out'
	} else if result.output_limited != 0 {
		'output_limited'
	} else if result.exit_code == 0 {
		'succeeded'
	} else {
		'failed'
	}
	return ShellCommandResult{
		status:    status
		exit_code: result.exit_code
		output:    safe_output
	}
}
