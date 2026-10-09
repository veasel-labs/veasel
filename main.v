module main

import os
import veb

const default_port = 4097

fn serve(port int, data_dir string) ! {
	mut store := open_store(os.join_path(data_dir, 'veasel.sqlite3'))!
	defer {
		store.close() or { eprintln('veasel: unable to close session store') }
	}
	mut app := &App{
		store: store
	}
	veb.run_at[App, Context](mut app, host: '127.0.0.1', family: .ip, port: port)!
}

fn launch_tui() {
	tui_dir := os.join_path(os.dir(@FILE), 'tui')
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
	command := if args.len > 0 { args[0] } else { 'serve' }
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
		println('Veasel Code ${version}\n\nCommands:\n  serve    Start the local V backend\n  tui      Start the terminal client (Bun required)\n\nEnvironment: VEASEL_PORT, VEASEL_DATA_DIR')
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
			launch_tui()
		}
		else {
			eprintln('unknown command: ${command}')
			exit(2)
		}
	}
}
