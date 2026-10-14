module main

import os
import net.http
import json2
import time
import veb

const default_port = 4097
const product_version = $d('veasel_version', '0.1.0-dev')

fn serve(port int, data_dir string) ! {
	mut store := open_store(os.join_path(data_dir, 'veasel.sqlite3'))!
	defer {
		store.close() or { eprintln('veasel: unable to close session store') }
	}
	plugin_directory := os.getenv_opt('VEASEL_PLUGIN_DIR') or {
		os.join_path(data_dir, 'plugins')
	}
	os.mkdir_all(plugin_directory)!
	mut app := new_app(store, plugin_directory)
	defer {
		app.close()
	}
	veb.run_at[App, Context](mut app, host: '127.0.0.1', family: .ip, port: port)!
}

fn backend_is_healthy(port int) bool {
	response := http.fetch(
		url:           'http://127.0.0.1:${port}/v1/health'
		read_timeout:  500 * time.millisecond
		write_timeout: 500 * time.millisecond
		max_retries:   1
	) or { return false }
	if response.status_code != 200 {
		return false
	}
	health := json2.decode[Health](response.body) or { return false }
	return health.healthy
}

fn spawn_backend_server(mut process os.Process, log_path string) ! {
	// Veb and fasthttp write their startup banners directly to stdout. A child
	// backend inherits the CLI's stdout by default, which corrupts `veasel run
	// --json` when that command starts the backend itself. Give the child a
	// duplicate of stderr for stdout while spawning, then restore the CLI's
	// original stdout before it emits its own result.
	original_stdout_fd := os.fd_dup(1)
	if original_stdout_fd < 0 {
		return error('unable to preserve stdout while starting the Veasel server')
	}
	flush_stdout()
	if log_path.len > 0 {
		spawn_backend_with_log(mut process, log_path, original_stdout_fd)!
		return
	}
	if os.fd_dup2(2, 1) < 0 {
		os.fd_close(original_stdout_fd)
		return error('unable to redirect server startup output')
	}
	process.run()
	restore_result := os.fd_dup2(original_stdout_fd, 1)
	os.fd_close(original_stdout_fd)
	if restore_result < 0 {
		return error('unable to restore stdout after starting the Veasel server')
	}
	flush_stdout()
}

// The TUI owns the terminal, so a backend started for it writes stdout and
// stderr to a log file instead; otherwise server diagnostics corrupt the screen.
fn spawn_backend_with_log(mut process os.Process, log_path string, original_stdout_fd int) ! {
	original_stderr_fd := os.fd_dup(2)
	if original_stderr_fd < 0 {
		os.fd_close(original_stdout_fd)
		return error('unable to preserve stderr while starting the Veasel server')
	}
	os.mkdir_all(os.dir(log_path)) or {
		os.fd_close(original_stdout_fd)
		os.fd_close(original_stderr_fd)
		return error('unable to create the server log directory: ${err}')
	}
	mut log_file := os.open_file(log_path, 'a', 0o600) or {
		os.fd_close(original_stdout_fd)
		os.fd_close(original_stderr_fd)
		return error('unable to open the server log ${log_path}: ${err}')
	}
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

fn ensure_backend(port int, log_path string) ! {
	if backend_is_healthy(port) {
		return
	}
	mut process := os.new_process(os.executable())
	process.set_args(['serve'])
	spawn_backend_server(mut process, log_path)!
	for _ in 0 .. 150 {
		if backend_is_healthy(port) {
			return
		}
		if !process.is_alive() {
			process.wait()
			message := process.err
			process.close()
			return error('Veasel server exited before becoming healthy${if message.len > 0 {
				': ${message}'
			} else if log_path.len > 0 {
				'; see ${log_path}'
			} else {
				''
			}}')
		}
		time.sleep(100 * time.millisecond)
	}
	process.signal_kill()
	process.wait()
	process.close()
	return error('Veasel server did not become healthy on 127.0.0.1:${port} within 15 seconds')
}

fn server_log_path(data_dir string) string {
	return os.join_path(data_dir, 'logs', 'server.log')
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
	data_dir := os.getenv_opt('VEASEL_DATA_DIR') or {
		os.join_path(os.home_dir(), '.local', 'share', 'veasel')
	}
	requested_port := os.getenv('VEASEL_PORT').int()
	port := if requested_port > 0 && requested_port < 65536 {
		requested_port
	} else {
		default_port
	}
	if command in ['--help', '-h', 'help'] {
		println('Veasel Code ${product_version}\n\nCommands:\n  veasel         Start or reuse the local V backend, then open the TUI\n  serve          Start the local V backend only\n  tui            Start the TUI, starting the backend if needed\n  run            Run a task non-interactively in a persisted session\n\nOptions:\n  --help, -h       Show this help\n  --version, -v    Show the product version\n\nEnvironment: VEASEL_PORT, VEASEL_DATA_DIR, VEASEL_PLUGIN_DIR\n\nExamples:\n  veasel\n  veasel serve\n  veasel tui\n  veasel run --prompt "Explain this codebase"\n  veasel --version')
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
		else {
			eprintln('unknown command: ${command}')
			exit(2)
		}
	}
}
