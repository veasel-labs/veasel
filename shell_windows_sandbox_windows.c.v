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

struct C.VeaselWinMcpStdio {
	ok                int
	setup_failed      int
	used_appcontainer int
	used_job_object   int
	pid               u32
	process_handle    voidptr
	thread_handle     voidptr
	job_handle        voidptr
	stdin_write       voidptr
	stdout_read       voidptr
	stderr_read       voidptr
	error_message     [512]char
}

fn C.veasel_win_sandbox_available() int
fn C.veasel_win_run_sandboxed_shell(comspec_utf8 &char, command_utf8 &char, workdir_utf8 &char,
	timeout_ms int, max_output_bytes int, allow_network int, result &C.VeaselWinSandboxResult) int
fn C.veasel_win_sandbox_result_free(result &C.VeaselWinSandboxResult)
fn C.veasel_win_mcp_stdio_start(exe_utf8 &char, args_utf8 &&char, argc int, workdir_utf8 &char,
	plugin_root_utf8 &char, plugin_data_utf8 &char, env_utf8 &char, out &C.VeaselWinMcpStdio) int
fn C.veasel_win_mcp_stdio_is_alive(proc &C.VeaselWinMcpStdio) int
fn C.veasel_win_mcp_stdio_write_stdin(proc &C.VeaselWinMcpStdio, data &char, len int) int
fn C.veasel_win_mcp_stdio_pending(proc &C.VeaselWinMcpStdio, which int) int
fn C.veasel_win_mcp_stdio_read(proc &C.VeaselWinMcpStdio, which int, buf &char, cap int, out_len &int) int
fn C.veasel_win_mcp_stdio_terminate(proc &C.VeaselWinMcpStdio)
fn C.veasel_win_mcp_stdio_close(proc &C.VeaselWinMcpStdio)

fn windows_appcontainer_backend_available() bool {
	return C.veasel_win_sandbox_available() != 0
}

// WindowsMcpStdioProcess owns AppContainer + Job handles for a long-lived MCP
// stdio child. Kept heap-allocated so PluginMCPTransport can keep it alive.
@[heap]
struct WindowsMcpStdioProcess {
mut:
	raw      C.VeaselWinMcpStdio
	filename string
	closed   bool
}

fn windows_mcp_env_block(env map[string]string) string {
	mut block := ''
	for key, value in env {
		block += '${key}=${value}\0'
	}
	block += '\0'
	return block
}

fn start_windows_mcp_stdio_process(root string, data string, cwd string, command string, args []string,
	env map[string]string) !&WindowsMcpStdioProcess {
	normalized_root := root.trim_right('\\/').to_lower()
	normalized_data := data.trim_right('\\/').to_lower()
	for broad_root in ['c:', 'c:\\windows', 'c:\\users', 'c:\\program files', 'c:\\program files (x86)',
		'c:\\programdata'] {
		if normalized_root == broad_root || normalized_data == broad_root {
			return error('Trusted MCP stdio refused: PLUGIN_ROOT or PLUGIN_DATA is too broad for the sandbox')
		}
	}
	if !windows_appcontainer_backend_available() {
		return error('Trusted MCP stdio could not create a Windows AppContainer')
	}
	mut proc := &WindowsMcpStdioProcess{
		filename: command
	}
	env_block := windows_mcp_env_block(env)
	mut arg_ptrs := []&char{}
	for arg in args {
		arg_ptrs << arg.str
	}
	args_base := if arg_ptrs.len == 0 {
		unsafe { &&char(nil) }
	} else {
		unsafe { &&char(&arg_ptrs[0]) }
	}
	ok := C.veasel_win_mcp_stdio_start(command.str, args_base, arg_ptrs.len, cwd.str, root.str,
		data.str, env_block.str, &proc.raw)
	if ok == 0 || proc.raw.setup_failed != 0 || proc.raw.ok == 0 {
		mut message := unsafe { cstring_to_vstring(&char(&proc.raw.error_message[0])) }
		C.veasel_win_mcp_stdio_close(&proc.raw)
		if message.len == 0 {
			message = 'Trusted MCP stdio failed to start inside a Windows AppContainer'
		}
		return error(message)
	}
	return proc
}

fn (p &WindowsMcpStdioProcess) is_alive() bool {
	if p.closed {
		return false
	}
	return C.veasel_win_mcp_stdio_is_alive(&p.raw) != 0
}

fn (mut p WindowsMcpStdioProcess) stdin_write(s string) {
	if p.closed || s.len == 0 {
		return
	}
	C.veasel_win_mcp_stdio_write_stdin(&p.raw, s.str, s.len)
}

fn (p &WindowsMcpStdioProcess) is_pending_stdout() bool {
	if p.closed {
		return false
	}
	return C.veasel_win_mcp_stdio_pending(&p.raw, 1) != 0
}

fn (p &WindowsMcpStdioProcess) is_pending_stderr() bool {
	if p.closed {
		return false
	}
	return C.veasel_win_mcp_stdio_pending(&p.raw, 2) != 0
}

fn (mut p WindowsMcpStdioProcess) stdout_read() string {
	return p.read_pipe(1)
}

fn (mut p WindowsMcpStdioProcess) stderr_read() string {
	return p.read_pipe(2)
}

fn (mut p WindowsMcpStdioProcess) read_pipe(which int) string {
	if p.closed {
		return ''
	}
	mut buf := []u8{len: 65536}
	mut out_len := 0
	if C.veasel_win_mcp_stdio_read(&p.raw, which, &buf[0], buf.len, &out_len) == 0 || out_len <= 0 {
		return ''
	}
	return buf[..out_len].bytestr()
}

fn (mut p WindowsMcpStdioProcess) signal_kill() {
	if p.closed {
		return
	}
	C.veasel_win_mcp_stdio_terminate(&p.raw)
}

fn (mut p WindowsMcpStdioProcess) close() {
	if p.closed {
		return
	}
	p.closed = true
	C.veasel_win_mcp_stdio_close(&p.raw)
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
