module main

import json2
import net.http
import os

const headless_goals_help = 'Usage: veasel goals list | show <id> | admit <manifest.json>

Records and reads portable goal manifests through the authenticated local API.
Commands print JSON. Admission does not start workers.'

struct HeadlessGoalRequest {
	method http.Method
	path   string
	file   string
}

fn parse_headless_goal_args(args []string) !HeadlessGoalRequest {
	if args == ['list'] {
		return HeadlessGoalRequest{
			method: .get
			path:   '/v1/goals'
		}
	}
	if args.len == 2 {
		match args[0] {
			'show' {
				if !valid_goal_id(args[1]) {
					return error('invalid goal id')
				}
				return HeadlessGoalRequest{
					method: .get
					path:   '/v1/goals/${args[1]}'
				}
			}
			'admit' {
				return HeadlessGoalRequest{
					method: .post
					path:   '/v1/goals'
					file:   args[1]
				}
			}
			else {}
		}
	}
	return error('expected list, show <id>, or admit <manifest.json>')
}

fn execute_headless_goal_command(port int, args []string) {
	if args.len == 0 || args[0] in ['help', '--help', '-h'] {
		println(headless_goals_help)
		return
	}
	request := parse_headless_goal_args(args) or {
		eprintln('veasel goals: ${err}')
		exit(2)
	}
	mut data := ''
	if request.method == .post {
		if !os.is_file(request.file) || os.file_size(request.file) > 1024 * 1024 {
			eprintln('veasel goals: manifest must be a regular JSON file of at most 1 MiB')
			exit(2)
		}
		data = os.read_file(request.file) or {
			eprintln('veasel goals: unable to read manifest: ${err}')
			exit(2)
		}
	}
	ensure_backend(port, '') or {
		eprintln('veasel goals: ${err}')
		exit(1)
	}
	response := headless_json_request(port, request.method, request.path, data, false, '') or {
		eprintln('veasel goals: ${err}')
		exit(1)
	}
	if response.status_code !in [200, 201] {
		api_error := json2.decode[APIError](response.body) or {
			APIError{ error: 'HTTP ${response.status_code}' }
		}
		eprintln('veasel goals: ${api_error.error}')
		exit(1)
	}
	println(response.body)
}
