module main

import os
import net
import net.http
import json2
import time
import veb

const default_port = 4097
const product_version = $d('veasel_version', '0.1.0-dev')

// veb/fasthttp panics inside socket creation when the bind fails, which
// buries "port in use" under a stack trace (in the server log when
// spawned). Preflight so the failure is one actionable line. Occupancy is
// probed by connecting first: on Windows, SO_REUSEADDR lets a second
// bind to an occupied port succeed, so listen alone cannot detect it
// there. The listen probe then covers non-occupancy bind failures. The
// tiny probe-then-bind race is acceptable: worst case the panic path
// remains for a port taken in between.
fn check_port_available(port int) ! {
	in_use := error('port ${port} on 127.0.0.1 is already in use; stop the process using it or set VEASEL_PORT to a free port')
	if mut conn := net.dial_tcp('127.0.0.1:${port}') {
		conn.close() or {}
		return in_use
	}
	mut listener := net.listen_tcp(.ip, '127.0.0.1:${port}', net.ListenOptions{}) or {
		return in_use
	}
	listener.close() or {}
}

fn serve(port int, data_dir string) ! {
	check_port_available(port)!
	mut store := open_store(os.join_path(data_dir, 'veasel.sqlite3'))!
	defer {
		store.close() or { eprintln('veasel: unable to close session store') }
	}
	plugin_directory := os.getenv_opt('VEASEL_PLUGIN_DIR') or {
		os.join_path(data_dir, 'plugins')
	}
	ensure_directory(plugin_directory)!
	mut app := new_app(store, plugin_directory)
	defer {
		app.close()
	}
	veb.run_at[App, Context](mut app, host: '127.0.0.1', family: .ip, port: port)!
}

fn backend_health(port int) ?Health {
	response := http.fetch(
		url:           'http://127.0.0.1:${port}/v1/health'
		read_timeout:  500 * time.millisecond
		write_timeout: 500 * time.millisecond
		max_retries:   1
	) or { return none }
	if response.status_code != 200 {
		return none
	}
	health := json2.decode[Health](response.body) or { return none }
	if !health.healthy {
		return none
	}
	return health
}

fn backend_is_healthy(port int) bool {
	return backend_health(port) != none
}

// Empty unless the running server reports a different version than this
// CLI. Reusing a stale server after an upgrade silently runs the old
// backend (old tools, permissions, and schema), so name both versions and
// the server pid; there is no stop command yet, killing the pid is the
// restart path and the next invocation spawns a fresh server.
fn stale_server_warning(health Health) string {
	if health.version.len == 0 || health.version == product_version {
		return ''
	}
	stop := $if windows {
		'taskkill /PID ${health.pid}'
	} $else {
		'kill ${health.pid}'
	}
	pid_note := if health.pid > 0 {
		' To restart it with this version, stop pid ${health.pid} (`${stop}`) and retry.'
	} else {
		' Stop the running server and retry to use this version.'
	}
	return 'veasel: reusing a running ${health.version} server; this CLI is ${product_version}.${pid_note}'
}

fn spawn_backend_server(mut process os.Process, log_path string) ! {
	// Veb and fasthttp write their startup banners directly to stdout. A child
	// backend inherits the CLI's stdout by default, which corrupts `veasel run
	// --json` when that command starts the backend itself. Redirecting the
	// child to the CLI's stderr instead is just as harmful for headless use:
	// the long-lived server then holds the caller's stderr pipe open, so
	// `veasel run ... | consumer` and `$(veasel run ...)` never see EOF after
	// the CLI exits. The server always writes to a log file; a log path is
	// required so no caller can reintroduce descriptor inheritance.
	if log_path.len == 0 {
		return error('a server log path is required to start the Veasel server')
	}
	original_stdout_fd := os.fd_dup(1)
	if original_stdout_fd < 0 {
		return error('unable to preserve stdout while starting the Veasel server')
	}
	if !fd_set_cloexec(original_stdout_fd) {
		os.fd_close(original_stdout_fd)
		return error('unable to keep stdout out of the Veasel server process')
	}
	flush_stdout()
	spawn_backend_with_log(mut process, log_path, original_stdout_fd)!
	flush_stdout()
}

// A spawned backend writes stdout and stderr to a log file: the TUI owns
// the terminal screen, and headless callers own their stdout/stderr pipes.
fn spawn_backend_with_log(mut process os.Process, log_path string, original_stdout_fd int) ! {
	original_stderr_fd := os.fd_dup(2)
	if original_stderr_fd < 0 {
		os.fd_close(original_stdout_fd)
		return error('unable to preserve stderr while starting the Veasel server')
	}
	if !fd_set_cloexec(original_stderr_fd) {
		os.fd_close(original_stdout_fd)
		os.fd_close(original_stderr_fd)
		return error('unable to keep stderr out of the Veasel server process')
	}
	ensure_directory(os.dir(log_path)) or {
		os.fd_close(original_stdout_fd)
		os.fd_close(original_stderr_fd)
		return error('unable to create the server log directory: ${err}')
	}
	mut log_file := os.open_file(log_path, 'a', 0o600) or {
		os.fd_close(original_stdout_fd)
		os.fd_close(original_stderr_fd)
		return error('unable to open the server log ${log_path}: ${err}')
	}
	// The child receives the log via dup2 onto 1/2 (dup2 clears cloexec on
	// the target); the log's own descriptor must not leak as an extra fd.
	fd_set_cloexec(log_file.fd)
	flush_stderr()
	redirected := os.fd_dup2(log_file.fd, 1) >= 0 && os.fd_dup2(log_file.fd, 2) >= 0
	if redirected {
		process.run()
	}
	restore_stdout := os.fd_dup2(original_stdout_fd, 1)
	restore_stderr := os.fd_dup2(original_stderr_fd, 2)
	os.fd_close(original_stdout_fd)
	os.fd_close(original_stderr_fd)
	log_file.close()
	if !redirected {
		return error('unable to redirect server output to ${log_path}')
	}
	if restore_stdout < 0 || restore_stderr < 0 {
		return error('unable to restore terminal output after starting the Veasel server')
	}
}

// Callers without an explicit log path (the headless commands) still get
// the standard per-data-directory server log, never inherited descriptors.
fn backend_log_path(log_path string) string {
	if log_path.len > 0 {
		return log_path
	}
	return server_log_path(default_data_dir())
}

fn ensure_backend(port int, log_path string) ! {
	if health := backend_health(port) {
		warning := stale_server_warning(health)
		if warning.len > 0 {
			eprintln(warning)
		}
		return
	}
	effective_log_path := backend_log_path(log_path)
	mut process := os.new_process(os.executable())
	process.set_args(['serve'])
	spawn_backend_server(mut process, effective_log_path)!
	for _ in 0 .. 150 {
		if backend_is_healthy(port) {
			return
		}
		if !process.is_alive() {
			process.wait()
			message := process.err
			process.close()
			// Another CLI may have won the spawn race while our child
			// lost the bind; that is success, not failure.
			if backend_is_healthy(port) {
				return
			}
			// Something else holds the port and is not a Veasel server:
			// say so directly instead of pointing only at the log.
			check_port_available(port) or { return err }
			return error('Veasel server exited before becoming healthy${if message.len > 0 {
				': ${message}'
			} else {
				'; see ${effective_log_path}'
			}}')
		}
		time.sleep(100 * time.millisecond)
	}
	process.signal_kill()
	process.wait()
	process.close()
	return error('Veasel server did not become healthy on 127.0.0.1:${port} within 15 seconds')
}

// os.mkdir_all is check-then-create per path segment, so several CLIs
// cold-starting concurrently race: the losers get "File exists" for a
// segment a winner just created, possibly before the final directory
// exists. Retry briefly while the winner finishes; only a path that is
// still missing (or not a directory) after the retries fails.
fn ensure_directory(path string) ! {
	for attempt in 0 .. 50 {
		os.mkdir_all(path) or {
			if os.is_dir(path) {
				return
			}
			if attempt == 49 {
				return err
			}
			time.sleep(10 * time.millisecond)
			continue
		}
		return
	}
}

fn server_log_path(data_dir string) string {
	return os.join_path(data_dir, 'logs', 'server.log')
}

fn default_data_dir() string {
	return os.getenv_opt('VEASEL_DATA_DIR') or {
		os.join_path(os.home_dir(), '.local', 'share', 'veasel')
	}
}

fn tui_directory_for_executable(executable_path string) string {
	executable := os.real_path(executable_path)
	return os.join_path(os.dir(executable), 'tui')
}

fn tui_executable_for_executable(executable_path string) string {
	executable := os.real_path(executable_path)
	name := $if windows { 'veasel-tui.exe' } $else { 'veasel-tui' }
	return os.join_path(os.dir(executable), name)
}

fn launch_tui(port int, data_dir string) {
	ensure_backend(port, server_log_path(data_dir)) or {
		eprintln('veasel: ${err.msg()}')
		exit(1)
	}
	os.setenv('VEASEL_PROJECT_DIR', os.getwd(), true)
	tui_executable := tui_executable_for_executable(os.executable())
	if os.is_file(tui_executable) {
		os.execvp(tui_executable, []) or {
			eprintln('veasel: unable to start the bundled TUI: ${err}')
			exit(1)
		}
	}
	tui_dir := tui_directory_for_executable(os.executable())
	if !os.is_file(os.join_path(tui_dir, 'package.json')) {
		eprintln('veasel: the bundled TUI is missing at ${tui_executable}; development client not found at ${tui_dir}')
		exit(1)
	}
	os.execvp('bun', ['run', '--cwd', tui_dir, 'start']) or {
		eprintln('veasel: unable to start the TUI: ${err}')
		exit(1)
	}
}

fn command_help(command string) string {
	match command {
		'serve' {
			return 'Usage: veasel serve\n\nStart the local V backend only.\n\nEnvironment: VEASEL_PORT, VEASEL_DATA_DIR, VEASEL_PLUGIN_DIR'
		}
		'tui' {
			return 'Usage: veasel tui\n\nStart or reuse the local backend, then open the terminal UI.\n\nEnvironment: VEASEL_PORT, VEASEL_DATA_DIR, VEASEL_PLUGIN_DIR'
		}
		'mcp' {
			return 'Usage: veasel mcp <list|add|enable|disable|remove> [options]\n\nManage configured MCP servers through the local API (user or project scope).\nRun `veasel mcp --help` for full syntax. Trust and per-call approval stay in the TUI.\n\nEnvironment: VEASEL_PORT, VEASEL_DATA_DIR, VEASEL_PLUGIN_DIR'
		}
		else {
			return ''
		}
	}
}

fn main() {
	args := os.args[1..]
	command := if args.len > 0 { args[0] } else { 'tui' }
	if args.len > 1 && args[1] in ['--help', '-h'] {
		help := command_help(command)
		if help.len > 0 {
			println(help)
			return
		}
	}
	data_dir := default_data_dir()
	requested_port := os.getenv('VEASEL_PORT').int()
	port := if requested_port > 0 && requested_port < 65536 {
		requested_port
	} else {
		default_port
	}
	if command in ['--help', '-h', 'help'] {
		println('Veasel Code ${product_version}\n\nCommands:\n  veasel         Start or reuse the local V backend, then open the TUI\n  serve          Start the local V backend only\n  tui            Start the TUI, starting the backend if needed\n  run            Run a task non-interactively in a persisted session\n  mcp            List or manage configured MCP servers (user/project scope)\n  plugins        Enable or disable Agent Plugin skill/MCP components\n  config         Show or update local model provider settings\n  worktrees      List, add, remove, lock, unlock, or prune git worktrees\n  skills         List discovered standalone SKILL.md packages\n\nOptions:\n  --help, -h       Show this help\n  --version, -v    Show the product version\n\nEnvironment: VEASEL_PORT, VEASEL_DATA_DIR, VEASEL_PLUGIN_DIR\n\nExamples:\n  veasel\n  veasel serve\n  veasel tui\n  veasel run --prompt "Explain this codebase"\n  veasel mcp list\n  veasel mcp add stdio echo-tools true\n  veasel plugins components list\n  veasel plugins components disable demo mcp local\n  veasel plugins links list\n  veasel config model get\n  veasel config model set --provider meta --max-output-tokens 8192\n  veasel worktrees list\n  veasel skills list\n  veasel --version')
		return
	}
	if command in ['--version', '-v', 'version'] {
		println('Veasel Code ${product_version}')
		return
	}
	match command {
		'serve' {
			serve(port, data_dir) or {
				eprintln('veasel: ${err}')
				exit(1)
			}
		}
		'tui' {
			launch_tui(port, data_dir)
		}
		'run' {
			execute_headless_command(port, args[1..])
		}
		'mcp' {
			execute_headless_mcp_command(port, args[1..])
		}
		'plugins' {
			execute_headless_plugins_command(port, args[1..])
		}
		'config' {
			execute_headless_config_command(port, args[1..])
		}
		'worktrees' {
			execute_headless_worktrees_command(port, args[1..])
		}
		'skills' {
			execute_headless_skills_command(port, args[1..])
		}
		else {
			eprintln('unknown command: ${command}')
			exit(2)
		}
	}
}
