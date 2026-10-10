module main

import encoding.utf8
import json2
import os
import sync
import time

const max_shell_command_bytes = 8_192
const max_shell_command_timeout_seconds = 300
const max_shell_command_output_bytes = 65_536
const max_pending_shell_commands = 20
const shell_output_limited_marker = '\n[Output limit reached; remaining output was discarded]'

@[heap]
struct ShellCommandRegistry {
mut:
	mutex   &sync.Mutex
	workers &sync.WaitGroup
	closing bool
}

fn (app &App) begin_shell_operation() bool {
	mut registry := app.shell_operation_registry
	mut registry_lock := registry.mutex
	registry_lock.lock()
	if registry.closing {
		registry_lock.unlock()
		return false
	}
	mut workers := registry.workers
	workers.add(1)
	registry_lock.unlock()
	return true
}

fn (app &App) finish_shell_operation() {
	mut registry := app.shell_operation_registry
	mut workers := registry.workers
	workers.add(-1)
}

fn (app &App) close_shell_operations() {
	mut registry := app.shell_operation_registry
	mut registry_lock := registry.mutex
	registry_lock.lock()
	registry.closing = true
	registry_lock.unlock()
}

fn (app &App) wait_for_shell_operations() {
	mut registry := app.shell_operation_registry
	mut workers := registry.workers
	workers.wait()
}

pub struct ShellCommandSummary {
pub:
	id              string
	command         string
	cwd             string
	timeout_seconds int
	status          string
	exit_code       int
	output          string
	created_at      string
	updated_at      string
}

struct ShellCommandDraft {
	command         string
	cwd             string
	timeout_seconds int
}

struct ShellCommandResult {
	status    string
	exit_code int
	output    string
}

struct AgentShellCommandResult {
	id      string
	command string
	cwd     string
	note    string
}

fn prepare_shell_command(root string, command string, cwd string, timeout_seconds int) !ShellCommandDraft {
	if command.trim_space().len == 0 || command.len > max_shell_command_bytes || command.contains('\x00') {
		return error('command must contain 1 to ${max_shell_command_bytes} bytes and no NUL bytes')
	}
	if shell_text_has_unsafe_controls(command) {
		return error('command contains control or bidirectional formatting characters that cannot be safely reviewed')
	}
	if timeout_seconds < 1 || timeout_seconds > max_shell_command_timeout_seconds {
		return error('timeout must be from 1 to ${max_shell_command_timeout_seconds} seconds')
	}
	canonical_root := canonical_workspace_root(root)!
	relative_cwd := if cwd.trim_space().len == 0 { '.' } else { cwd }
	if relative_cwd.len > 4_096 || os.is_abs_path(relative_cwd) || relative_cwd.contains('\x00') {
		return error('working directory must be relative to the workspace')
	}
	if shell_text_has_unsafe_controls(relative_cwd) {
		return error('working directory contains unsafe control characters')
	}
	for segment in relative_cwd.replace('\\', '/').split('/') {
		if segment == '..' { return error('working directory must stay inside the workspace') }
	}
	directory := os.real_path(os.join_path(canonical_root, relative_cwd))
	if !path_is_within(canonical_root, directory) || !os.is_dir(directory) {
		return error('working directory must be an existing directory inside the workspace')
	}
	mut stored_cwd := '.'
	if directory != canonical_root {
		relative_path := os.path_rel(canonical_root, directory) or {
			return error('working directory is invalid')
		}
		stored_cwd = relative_path.replace('\\', '/')
	}
	return ShellCommandDraft{ command: command, cwd: stored_cwd, timeout_seconds: timeout_seconds }
}

fn shell_text_has_unsafe_controls(value string) bool {
	for character in value.runes() {
		if utf8.is_control(character) || character in [0x00ad, 0x034f, 0x061c, 0x180e, 0x200b,
			0x200c, 0x200d, 0x200e, 0x200f, 0x2028, 0x2029, 0x202a, 0x202b, 0x202c, 0x202d, 0x202e,
			0x2060, 0x2066, 0x2067, 0x2068, 0x2069, 0xfeff] {
			return true
		}
	}
	return false
}

fn run_approved_shell_command(root string, command ShellCommandSummary) ShellCommandResult {
	canonical_root := canonical_workspace_root(root) or {
		return ShellCommandResult{
			status:    'failed'
			exit_code: -1
			output:    'The reviewed workspace root is no longer safe or available; no process was started.'
		}
	}
	if canonical_root != root {
		return ShellCommandResult{
			status:    'failed'
			exit_code: -1
			output:    'The reviewed workspace root now resolves to a different path; no process was started.'
		}
	}
	verified := prepare_shell_command(canonical_root, command.command, command.cwd, command.timeout_seconds) or {
		return ShellCommandResult{
			status:    'failed'
			exit_code: -1
			output:    'The reviewed working directory is no longer safe or available; no process was started.'
		}
	}
	if verified.cwd != command.cwd {
		return ShellCommandResult{
			status:    'failed'
			exit_code: -1
			output:    'The reviewed working directory now resolves to a different path; no process was started.'
		}
	}
	$if windows {
		shell := os.getenv('COMSPEC')
		if shell.len == 0 {
			return ShellCommandResult{ status: 'failed', exit_code: -1, output: 'COMSPEC is not configured' }
		}
		mut process := os.new_process(shell)
		process.set_args(['/D', '/S', '/C', command.command])
		process.set_stdin_path('NUL')
		process.set_work_folder(os.join_path(canonical_root, verified.cwd))
		process.set_redirect_stdio()
		process.use_pgroup = true
		return collect_shell_process(mut process, command.timeout_seconds)
	} $else {
		mut process := os.new_process('/bin/sh')
		process.set_args(['-c', command.command])
		process.set_stdin_path('/dev/null')
		process.set_work_folder(os.join_path(canonical_root, verified.cwd))
		process.set_redirect_stdio()
		process.use_pgroup = true
		return collect_shell_process(mut process, command.timeout_seconds)
	}
}

fn collect_shell_process(mut process os.Process, timeout_seconds int) ShellCommandResult {
	process.run()
	deadline := time.sys_mono_now() + u64(timeout_seconds) * u64(time.second)
	mut output := []u8{cap: max_shell_command_output_bytes}
	mut output_limited := false
	mut timed_out := false
	for process.is_alive() {
		append_shell_output(mut output, process.stdout_read(), mut output_limited)
		append_shell_output(mut output, process.stderr_read(), mut output_limited)
		if output_limited {
			process.signal_pgkill()
			break
		}
		if time.sys_mono_now() >= deadline {
			timed_out = true
			process.signal_pgkill()
			break
		}
		time.sleep(10 * time.millisecond)
	}
	process.wait()
	append_shell_output(mut output, process.stdout_read(), mut output_limited)
	append_shell_output(mut output, process.stderr_read(), mut output_limited)
	code := process.code
	process.close()
	mut safe_output := output.bytestr()
	if safe_output.len > 0 {
		bytes := safe_output.bytes()
		if !utf8.validate(&bytes[0], bytes.len) {
			safe_output = '[Output omitted: command produced invalid UTF-8]'
		}
	}
	if output_limited { safe_output += shell_output_limited_marker }
	status := if timed_out {
		'timed_out'
	} else if output_limited {
		'output_limited'
	} else if code == 0 {
		'succeeded'
	} else {
		'failed'
	}
	return ShellCommandResult{ status: status, exit_code: code, output: safe_output }
}

fn append_shell_output(mut output []u8, chunk string, mut limited bool) {
	if chunk.len == 0 { return }
	available := max_shell_command_output_bytes - shell_output_limited_marker.len - output.len
	if chunk.len > available { limited = true }
	if available > 0 {
		chunk_bytes := chunk.bytes()
		byte_count := if chunk_bytes.len < available { chunk_bytes.len } else { available }
		output << chunk_bytes[..byte_count]
	}
}

fn parse_shell_tool_arguments(arguments string, root string) !ShellCommandDraft {
	fields := json2.decode[map[string]json2.Any](arguments)!
	if fields.len != 3 { return error('command, cwd, and timeout_seconds are required') }
	command := string_tool_argument(fields, 'command')!
	cwd := string_tool_argument(fields, 'cwd')!
	timeout_value := fields['timeout_seconds'] or { return error('timeout_seconds is required') }
	if timeout_value !is int { return error('timeout_seconds must be an integer') }
	return prepare_shell_command(root, command, cwd, timeout_value as int)
}
