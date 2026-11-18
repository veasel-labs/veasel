module main

import json2
import net.http
import os
import time

// `veasel token path|rotate`.
fn execute_token_command(port int, data_dir string, args []string) {
	if args.len == 0 || args[0] in ['--help', '-h'] {
		println(command_help('token'))
		return
	}
	match args[0] {
		'path' {
			if os.getenv(api_token_env).len > 0 {
				println('The API token comes from ${api_token_env}; no token file is used.')
				return
			}
			println(api_token_path(data_dir))
		}
		'rotate' {
			rotate_token_command(port, data_dir) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
			println('API token rotated. Clients re-read ${api_token_path(data_dir)} on their next connection; processes that cached the old token must be restarted.')
		}
		else {
			eprintln('unknown token command: ${args[0]}')
			exit(2)
		}
	}
}

fn rotate_token_command(port int, data_dir string) ! {
	if os.getenv(api_token_env).len > 0 {
		return error('the token is managed by ${api_token_env}; change that variable and restart the server')
	}
	if backend_is_healthy(port) {
		// A live server owns the verifier: rotate through it so the new
		// token takes effect immediately and the old one stops working.
		authorization := api_auth_header(data_dir) or {
			return error('a server is running on port ${port} but its token cannot be read from ${api_token_path(data_dir)}')
		}
		mut header := http.new_header()
		header.set(.authorization, authorization)
		response := http.fetch(
			url:           'http://127.0.0.1:${port}/v1/auth/rotate'
			method:        .post
			header:        header
			data:          ''
			read_timeout:  5 * time.second
			write_timeout: 5 * time.second
			max_retries:   1
		)!
		if response.status_code != 200 {
			message := json2.decode[APIError](response.body) or { APIError{} }
			return error('rotation refused (HTTP ${response.status_code}): ${message.error}')
		}
		return
	}
	// No server: nothing holds the old value in memory, so rewriting the
	// file is the whole rotation.
	replace_api_token(data_dir)!
}
