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

fn ensure_backend(port int) ! {
	if backend_is_healthy(port) {
		return
	}
	mut process := os.new_process(os.executable())
	process.set_args(['serve'])
	process.run()
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

fn tui_directory_for_executable(executable_path string) string {
	executable := os.real_path(executable_path)
	return os.join_path(os.dir(executable), 'tui')
}

fn launch_tui(port int) {
	ensure_backend(port) or {
		eprintln('veasel: ${err.msg()}')
		exit(1)
	}
	tui_dir := tui_directory_for_executable(os.executable())
	if !os.is_file(os.join_path(tui_dir, 'package.json')) {
		eprintln('veasel: the TUI package is missing at ${tui_dir}')
		exit(1)
	}
	os.setenv('VEASEL_PROJECT_DIR', os.getwd(), true)
	os.execvp('bun', ['run', '--cwd', tui_dir, 'start']) or {
		eprintln('veasel: unable to start the TUI: ${err}')
		exit(1)
	}
}

fn main() {
	args := os.args[1..]
	command := if args.len > 0 { args[0] } else { 'tui' }
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
		println('Veasel Code ${product_version}\n\nCommands:\n  veasel         Start or reuse the local V backend, then open the TUI\n  serve          Start the local V backend only\n  tui            Start the TUI, starting the backend if needed\n\nOptions:\n  --help, -h       Show this help\n  --version, -v    Show the product version\n\nEnvironment: VEASEL_PORT, VEASEL_DATA_DIR, VEASEL_PLUGIN_DIR\n\nExamples:\n  veasel\n  veasel serve\n  veasel tui\n  veasel --version')
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
			launch_tui(port)
		}
		else {
			eprintln('unknown command: ${command}')
			exit(2)
		}
	}
}
