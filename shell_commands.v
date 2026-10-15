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

const shell_sandbox_mode_env = 'VEASEL_SHELL_SANDBOX'
const shell_sandbox_network_env = 'VEASEL_SHELL_SANDBOX_NETWORK'

// ApprovedShellSandboxMode selects defense-in-depth OS sandboxing for reviewed
// commands (Bubblewrap on Linux, Seatbelt on macOS). Autonomous execution always
// uses fail-closed Bubblewrap on Linux only.
enum ApprovedShellSandboxMode {
	auto
	off
	require
}

struct LinuxShellSandboxOptions {
	purpose            string
	fail_closed        bool
	filter_environment bool
	allow_network      bool
}

struct MacosShellSandboxOptions {
	purpose       string
	fail_closed   bool
	allow_network bool
}

const macos_seatbelt_executable = '/usr/bin/sandbox-exec'

fn approved_shell_sandbox_mode_from(value string) ApprovedShellSandboxMode {
	match value.trim_space().to_lower() {
		'', 'auto' {
			return .auto
		}
		'off', '0', 'false', 'none', 'disable', 'disabled' {
			return .off
		}
		'require', 'required', 'must', 'strict' {
			return .require
		}
		else {
			return .auto
		}
	}
}

fn approved_shell_sandbox_mode() ApprovedShellSandboxMode {
	return approved_shell_sandbox_mode_from(os.getenv(shell_sandbox_mode_env))
}

fn approved_shell_sandbox_network_allowed_from(value string) bool {
	return value.trim_space().to_lower() in ['allow', '1', 'true', 'yes', 'on']
}

fn approved_shell_sandbox_network_allowed() bool {
	return approved_shell_sandbox_network_allowed_from(os.getenv(shell_sandbox_network_env))
}

fn bubblewrap_executable_path() !string {
	return os.find_abs_path_of_executable('bwrap')
}

fn bubblewrap_available() bool {
	$if linux {
		bubblewrap_executable_path() or { return false }
		return true
	} $else {
		return false
	}
}

// shell_sandbox_bubblewrap_capability is true only when Linux Bubblewrap will
// actually wrap approved shell commands for the current process configuration.
fn shell_sandbox_bubblewrap_capability() bool {
	$if linux {
		if approved_shell_sandbox_mode() == .off {
			return false
		}
		return bubblewrap_available()
	} $else {
		return false
	}
}

fn seatbelt_available() bool {
	$if macos {
		return os.is_file(macos_seatbelt_executable) && os.is_executable(macos_seatbelt_executable)
	} $else {
		return false
	}
}

// shell_sandbox_seatbelt_capability is true only when macOS Seatbelt will
// actually wrap approved shell commands for the current process configuration.
fn shell_sandbox_seatbelt_capability() bool {
	$if macos {
		if approved_shell_sandbox_mode() == .off {
			return false
		}
		return seatbelt_available()
	} $else {
		return false
	}
}

// shell_sandbox_windows_capability stays false until Veasel can wrap approved
// Windows shell in a real OS isolation backend without pretending.
fn shell_sandbox_windows_capability() bool {
	return false
}

fn run_approved_shell_command(root string, command ShellCommandSummary) ShellCommandResult {
	return run_approved_shell_command_with_policy(root, command, false)
}

fn run_approved_shell_command_with_policy(root string, command ShellCommandSummary,
	sanitize_environment bool) ShellCommandResult {
	// Reviewers may pass a non-canonical path (for example /var vs /private/var
	// on macOS). Compare against real_path so equivalent roots still run, while
	// rejecting a root that re-resolves to a different safe location.
	expected_root := os.real_path(root)
	canonical_root := canonical_workspace_root(root) or {
		return ShellCommandResult{
			status:    'failed'
			exit_code: -1
			output:    'The reviewed workspace root is no longer safe or available; no process was started.'
		}
	}
	if canonical_root != expected_root {
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
	if sanitize_environment {
		$if linux {
			return run_linux_sandboxed_shell_command(canonical_root, verified.cwd, command,
				LinuxShellSandboxOptions{
					purpose:            'Autonomous shell execution'
					fail_closed:        true
					filter_environment: true
					allow_network:      false
				})
		} $else {
			return ShellCommandResult{
				status:    'failed'
				exit_code: -1
				output:    'Autonomous shell execution is unavailable on this platform because Veasel cannot enforce its required operating-system sandbox.'
			}
		}
	}
	mode := approved_shell_sandbox_mode()
	$if linux {
		if mode != .off {
			if bubblewrap_available() {
				return run_linux_sandboxed_shell_command(canonical_root, verified.cwd, command,
					LinuxShellSandboxOptions{
						purpose:            'Approved shell execution'
						fail_closed:        mode == .require
						filter_environment: false
						allow_network:      approved_shell_sandbox_network_allowed()
					})
			}
			if mode == .require {
				return ShellCommandResult{
					status:    'failed'
					exit_code: -1
					output:    'Approved shell execution requires bubblewrap (bwrap) because VEASEL_SHELL_SANDBOX=require; no unsandboxed fallback was started.'
				}
			}
			// VEASEL_SHELL_SANDBOX=auto and bwrap missing: fall through unsandboxed.
		}
	} $else $if macos {
		if mode != .off {
			if seatbelt_available() {
				return run_macos_sandboxed_shell_command(canonical_root, verified.cwd, command,
					MacosShellSandboxOptions{
						purpose:       'Approved shell execution'
						fail_closed:   mode == .require
						allow_network: approved_shell_sandbox_network_allowed()
					})
			}
			if mode == .require {
				return ShellCommandResult{
					status:    'failed'
					exit_code: -1
					output:    'Approved shell execution requires /usr/bin/sandbox-exec because VEASEL_SHELL_SANDBOX=require; no unsandboxed fallback was started.'
				}
			}
			// VEASEL_SHELL_SANDBOX=auto and sandbox-exec missing: fall through unsandboxed.
		}
	} $else $if windows {
		if mode == .require {
			return ShellCommandResult{
				status:    'failed'
				exit_code: -1
				output:    'Approved shell execution requires a Windows OS sandbox because VEASEL_SHELL_SANDBOX=require; Veasel does not yet wrap approved Windows shell in Job Object, AppContainer, or restricted-token isolation, so no unsandboxed fallback was started.'
			}
		}
	} $else {
		if mode == .require {
			return ShellCommandResult{
				status:    'failed'
				exit_code: -1
				output:    'Approved shell execution requires an OS sandbox because VEASEL_SHELL_SANDBOX=require; this platform has no Veasel sandbox backend, so no unsandboxed fallback was started.'
			}
		}
	}
	$if windows {
		shell := os.getenv('COMSPEC')
		if shell.len == 0 {
			return ShellCommandResult{ status: 'failed', exit_code: -1, output: 'COMSPEC is not configured' }
		}
		mut process := os.new_process(shell)
		process.set_args(['/D', '/S', '/C', command.command])
		if sanitize_environment {
			process.set_environment(autonomous_shell_environment())
		}
		process.set_stdin_path('NUL')
		process.set_work_folder(os.join_path(canonical_root, verified.cwd))
		process.set_redirect_stdio()
		process.use_pgroup = true
		return collect_shell_process(mut process, command.timeout_seconds)
	} $else {
		mut process := os.new_process('/bin/sh')
		process.set_args(['-c', command.command])
		if sanitize_environment {
			process.set_environment(autonomous_shell_environment())
		}
		process.set_stdin_path('/dev/null')
		process.set_work_folder(os.join_path(canonical_root, verified.cwd))
		process.set_redirect_stdio()
		process.use_pgroup = true
		return collect_shell_process(mut process, command.timeout_seconds)
	}
}

// Linux Bubblewrap policy (approved when available; autonomous fail-closed):
// - host root is read-only; only the workspace bind is writable
// - /home, /root, /run, /mnt, /media, and /tmp are masked with tmpfs when present
// - namespaces are unshared; network stays isolated unless allow_network is set
// - Bubblewrap is a host capability, not a bundled V runtime dependency
fn run_linux_sandboxed_shell_command(root string, cwd string, command ShellCommandSummary,
	options LinuxShellSandboxOptions) ShellCommandResult {
	purpose := if options.purpose.len == 0 { 'Shell execution' } else { options.purpose }
	for broad_root in ['/', '/home', '/root', '/tmp', '/mnt', '/media', '/var', '/usr', '/etc',
		'/opt', '/boot', '/sys', '/proc', '/dev', '/run', '/bin', '/sbin', '/lib', '/lib64'] {
		if root == broad_root {
			return ShellCommandResult{
				status:    'failed'
				exit_code: -1
				output:    '${purpose} refused: the workspace root is too broad for the enforced sandbox.'
			}
		}
	}
	bwrap := bubblewrap_executable_path() or {
		if options.fail_closed {
			return ShellCommandResult{
				status:    'failed'
				exit_code: -1
				output:    '${purpose} requires bubblewrap (bwrap); no unsandboxed fallback was started.'
			}
		}
		return ShellCommandResult{
			status:    'failed'
			exit_code: -1
			output:    '${purpose} could not locate bubblewrap (bwrap); no process was started.'
		}
	}
	mut args := [
		'--unshare-all',
		'--die-with-parent',
		'--new-session',
		'--ro-bind',
		'/',
		'/',
	]
	if options.allow_network {
		args << '--share-net'
	}
	for hidden_path in ['/home', '/root', '/run', '/mnt', '/media', '/tmp'] {
		if os.is_dir(hidden_path) {
			args << '--tmpfs'
			args << hidden_path
		}
	}
	args << '--proc'
	args << '/proc'
	args << '--dev'
	args << '/dev'
	mut parent := ''
	for component in root.split('/') {
		if component.len == 0 {
			continue
		}
		parent = if parent.len == 0 { '/${component}' } else { '${parent}/${component}' }
		args << '--dir'
		args << parent
	}
	args << '--bind'
	args << root
	args << root
	args << '--chdir'
	args << os.join_path(root, cwd)
	args << '--'
	args << '/bin/sh'
	args << '-c'
	args << command.command
	mut process := os.new_process(bwrap)
	process.set_args(args)
	mut environment := map[string]string{}
	if options.filter_environment {
		environment = autonomous_shell_environment()
	} else {
		environment = os.environ()
	}
	environment['HOME'] = '/tmp'
	environment['TMPDIR'] = '/tmp'
	process.set_environment(environment)
	process.set_stdin_path('/dev/null')
	process.set_redirect_stdio()
	process.use_pgroup = true
	return collect_shell_process(mut process, command.timeout_seconds)
}

// macOS Seatbelt policy for approved shell (principles adapted from Codex Seatbelt
// study; no upstream source copied):
// - sandbox-exec is taken only from /usr/bin/sandbox-exec
// - default deny; host remains readable; writes limited to workspace + temp
// - /Users, /var/root, and /Volumes are denied except the workspace carve-out
// - network stays denied unless allow_network is set
// - Seatbelt is best-effort containment via sandbox-exec, not a VM boundary
fn macos_seatbelt_profile(allow_network bool) string {
	mut lines := [
		'(version 1)',
		'(deny default)',
		'(allow process-exec)',
		'(allow process-fork)',
		'(allow signal (target self))',
		'(allow process-info* (target self))',
		'(allow sysctl-read)',
		'(allow mach-lookup (global-name "com.apple.system.opendirectoryd.libinfo"))',
		'(allow file-read-metadata)',
		'(allow file-read*)',
		'(allow file-write-data (require-all (literal "/dev/null") (vnode-type CHARACTER-DEVICE)))',
		'(allow file-write* (subpath (param "WORKSPACE")))',
		'(allow file-write* (subpath "/private/tmp"))',
		'(allow file-write* (subpath "/tmp"))',
		'(allow file-write* (subpath "/private/var/folders"))',
		'(allow file-write* (subpath "/var/folders"))',
		'(deny file-read* file-write* (require-all (subpath "/Users") (require-not (subpath (param "WORKSPACE")))))',
		'(deny file-read* file-write* (require-all (subpath "/var/root") (require-not (subpath (param "WORKSPACE")))))',
		'(deny file-read* file-write* (require-all (subpath "/private/var/root") (require-not (subpath (param "WORKSPACE")))))',
		'(deny file-read* file-write* (require-all (subpath "/Volumes") (require-not (subpath (param "WORKSPACE")))))',
	]
	if allow_network {
		lines << '(allow network-outbound)'
		lines << '(allow network-inbound)'
		lines << '(allow system-socket)'
	}
	return lines.join('\n')
}

fn run_macos_sandboxed_shell_command(root string, cwd string, command ShellCommandSummary,
	options MacosShellSandboxOptions) ShellCommandResult {
	purpose := if options.purpose.len == 0 { 'Shell execution' } else { options.purpose }
	for broad_root in ['/', '/Users', '/System', '/Library', '/Applications', '/private', '/var',
		'/usr', '/bin', '/sbin', '/etc', '/tmp', '/Volumes', '/Network', '/dev', '/cores'] {
		if root == broad_root {
			return ShellCommandResult{
				status:    'failed'
				exit_code: -1
				output:    '${purpose} refused: the workspace root is too broad for the enforced sandbox.'
			}
		}
	}
	if !seatbelt_available() {
		if options.fail_closed {
			return ShellCommandResult{
				status:    'failed'
				exit_code: -1
				output:    '${purpose} requires /usr/bin/sandbox-exec; no unsandboxed fallback was started.'
			}
		}
		return ShellCommandResult{
			status:    'failed'
			exit_code: -1
			output:    '${purpose} could not locate /usr/bin/sandbox-exec; no process was started.'
		}
	}
	profile := macos_seatbelt_profile(options.allow_network)
	mut args := [
		'-p',
		profile,
		'-DWORKSPACE=${root}',
		'--',
		'/bin/sh',
		'-c',
		command.command,
	]
	mut process := os.new_process(macos_seatbelt_executable)
	process.set_args(args)
	mut environment := os.environ()
	tmpdir := os.temp_dir()
	if tmpdir.len > 0 {
		environment['TMPDIR'] = tmpdir
	}
	process.set_environment(environment)
	process.set_stdin_path('/dev/null')
	process.set_work_folder(os.join_path(root, cwd))
	process.set_redirect_stdio()
	process.use_pgroup = true
	return collect_shell_process(mut process, command.timeout_seconds)
}

fn autonomous_shell_environment() map[string]string {
	return autonomous_shell_environment_from(os.environ())
}

fn autonomous_shell_environment_from(current map[string]string) map[string]string {
	mut filtered := map[string]string{}
	$if windows {
		allowed := ['PATH', 'SYSTEMROOT', 'WINDIR', 'COMSPEC', 'TEMP', 'TMP', 'USERPROFILE']
		for key in allowed {
			if value := current[key] {
				filtered[key] = value
			}
		}
	} $else {
		allowed := ['PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'LC_CTYPE', 'LC_MESSAGES', 'TERM']
		for key in allowed {
			if value := current[key] {
				filtered[key] = value
			}
		}
	}
	return filtered
}

fn collect_shell_process(mut process os.Process, timeout_seconds int) ShellCommandResult {
	process.run()
	deadline := time.sys_mono_now() + u64(timeout_seconds) * u64(time.second)
	mut output := []u8{cap: max_shell_command_output_bytes}
	mut output_limited := false
	mut timed_out := false
	for process.is_alive() {
		output_limited = append_shell_output(mut output, process.stdout_read(), output_limited)
		output_limited = append_shell_output(mut output, process.stderr_read(), output_limited)
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
	output_limited = append_shell_output(mut output, process.stdout_read(), output_limited)
	output_limited = append_shell_output(mut output, process.stderr_read(), output_limited)
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

fn append_shell_output(mut output []u8, chunk string, limited bool) bool {
	if chunk.len == 0 { return limited }
	available := max_shell_command_output_bytes - shell_output_limited_marker.len - output.len
	output_limited := limited || chunk.len > available
	if available > 0 {
		chunk_bytes := chunk.bytes()
		byte_count := if chunk_bytes.len < available { chunk_bytes.len } else { available }
		output << chunk_bytes[..byte_count]
	}
	return output_limited
}

fn parse_shell_tool_arguments(arguments string, root string) !ShellCommandDraft {
	fields := json2.decode[map[string]json2.Any](arguments)!
	if fields.len != 3 { return error('command, cwd, and timeout_seconds are required') }
	command := string_tool_argument(fields, 'command')!
	cwd := string_tool_argument(fields, 'cwd')!
	timeout_value := fields['timeout_seconds'] or { return error('timeout_seconds is required') }
	timeout_seconds := match timeout_value {
		int {
			timeout_value
		}
		i64 {
			if timeout_value < 1 || timeout_value > max_shell_command_timeout_seconds {
				return error('timeout_seconds must be an integer from 1 to ${max_shell_command_timeout_seconds}')
			}
			int(timeout_value)
		}
		f64 {
			if timeout_value < 1 || timeout_value > f64(max_shell_command_timeout_seconds)
				|| timeout_value != f64(int(timeout_value)) {
				return error('timeout_seconds must be an integer from 1 to ${max_shell_command_timeout_seconds}')
			}
			int(timeout_value)
		}
		else {
			return error('timeout_seconds must be an integer')
		}
	}
	return prepare_shell_command(root, command, cwd, timeout_seconds)
}
