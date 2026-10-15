module main

import json2
import net.http
import net.urllib
import os

struct HeadlessSkillsOptions {
mut:
	directory string
	json      bool
}

fn print_headless_skills_help() {
	println('Usage: veasel skills list [options]\n\nCommands:\n  list [--directory <dir>] [--json]\n\nOptions:\n  -w, --directory <dir>  Project directory for skill-root traversal (default: cwd)\n      --json             Emit machine-readable JSON\n  -h, --help             Show this help\n\nCalls GET /v1/skills. Returns metadata only; never prints instruction bodies or executes skill scripts.')
}

fn parse_headless_skills_args(args []string, cwd string) !HeadlessSkillsOptions {
	mut options := HeadlessSkillsOptions{
		directory: cwd
	}
	if args.len == 0 {
		return error('help')
	}
	mut index := 0
	action := args[index]
	index++
	if action in ['--help', '-h', 'help'] {
		return error('help')
	}
	if action != 'list' {
		return error('unknown skills command: ${action}')
	}
	for index < args.len {
		arg := args[index]
		match arg {
			'--directory', '-w' {
				index++
				if index >= args.len || args[index].trim_space().len == 0 {
					return error('--directory expects a project path')
				}
				options.directory = args[index]
			}
			'--json' {
				options.json = true
			}
			'--help', '-h' {
				return error('help')
			}
			else {
				return error('unknown skills option: ${arg}')
			}
		}
		index++
	}
	return options
}

fn headless_skills_api_error(response http.Response) string {
	decoded := json2.decode[APIError](response.body) or { return 'HTTP ${response.status_code}' }
	if decoded.error.len > 0 {
		return decoded.error
	}
	return 'HTTP ${response.status_code}'
}

fn execute_headless_skills_list(port int, options HeadlessSkillsOptions) !string {
	query := 'directory=${urllib.query_escape(options.directory)}'
	response := headless_json_request(port, .get, '/v1/skills?${query}', '', false, '')!
	if response.status_code != 200 {
		return error(headless_skills_api_error(response))
	}
	if options.json {
		return response.body
	}
	catalog := json2.decode[SkillsCatalog](response.body)!
	mut lines := []string{cap: catalog.skills.len + catalog.roots.len + 4}
	lines << 'Discovered skills (${catalog.skills.len})'
	for root in catalog.roots {
		lines << 'root  [${root.scope}] ${root.label}  ${root.path}'
	}
	if catalog.skills.len == 0 {
		lines << '(none)'
	}
	for skill in catalog.skills {
		tools := if skill.allowed_tools_declared {
			' · tools: ${skill.allowed_tools.join(', ')}'
		} else {
			''
		}
		lines << '${skill.key}  [${skill.scope}/${skill.source}]  ${skill.description}${tools}'
	}
	for diagnostic in catalog.diagnostics {
		lines << 'diagnostic  ${diagnostic.message}'
	}
	return lines.join('\n')
}

fn execute_headless_skills_command(port int, args []string) {
	options := parse_headless_skills_args(args, os.getwd()) or {
		if err.msg() == 'help' {
			print_headless_skills_help()
			return
		}
		eprintln('veasel: ${err.msg()}')
		print_headless_skills_help()
		exit(2)
	}
	ensure_backend(port, '') or {
		eprintln('veasel: ${err.msg()}')
		exit(1)
	}
	output := execute_headless_skills_list(port, options) or {
		eprintln('veasel: ${err.msg()}')
		exit(1)
	}
	println(output)
}
