module main

import json2
import net.http
import os

enum HeadlessWorktreesAction {
	list
	add
	remove
	lock
	unlock
	prune
}

struct HeadlessWorktreesOptions {
mut:
	action     HeadlessWorktreesAction
	workspace  string
	session_id string
	path       string
	branch     string
	new_branch string
	reason     string
	force      bool
	json       bool
}

fn print_headless_worktrees_help() {
	println('Usage: veasel worktrees <list|add|remove|lock|unlock|prune> [options]\n\nCommands:\n  list\n  add --path <abs> (--branch <name> | --new-branch <name>)\n  remove --path <abs> [--force]\n  lock --path <abs> [--reason <text>]\n  unlock --path <abs>\n  prune\n\nOptions:\n  -w, --workspace <dir>  Workspace for a new session (default: cwd)\n      --session <uuid>   Reuse an existing session instead of creating one\n      --path <abs>       Absolute worktree path (add/remove/lock/unlock)\n      --branch <name>    Existing branch for add\n      --new-branch <n>   Create branch with git worktree add -b\n      --reason <text>    Optional lock reason\n      --force            Pass --force to git worktree remove\n      --json             Emit machine-readable JSON\n  -h, --help             Show this help\n\nUses the local API: GET/POST/PATCH/DELETE /v1/sessions/{id}/workspace/git/worktrees.\nAdd/remove/lock/unlock/prune invoke argv-only git; listing is filesystem-only and reports missing checkouts.')
}

fn parse_headless_worktrees_args(args []string, cwd string) !HeadlessWorktreesOptions {
	mut options := HeadlessWorktreesOptions{
		workspace: cwd
	}
	if args.len == 0 {
		return error('help')
	}
	mut index := 0
	action := args[index]
	index++
	match action {
		'list' {
			options.action = .list
		}
		'add' {
			options.action = .add
		}
		'remove' {
			options.action = .remove
		}
		'lock' {
			options.action = .lock
		}
		'unlock' {
			options.action = .unlock
		}
		'prune' {
			options.action = .prune
		}
		'--help', '-h', 'help' {
			return error('help')
		}
		else {
			return error('unknown worktrees command: ${action}')
		}
	}
	for index < args.len {
		arg := args[index]
		match arg {
			'--workspace', '-w' {
				index++
				if index >= args.len || args[index].trim_space().len == 0 {
					return error('--workspace expects a directory path')
				}
				options.workspace = args[index]
			}
			'--session' {
				index++
				if index >= args.len || args[index].trim_space().len == 0 {
					return error('--session expects a session UUID')
				}
				options.session_id = args[index].trim_space()
			}
			'--path' {
				index++
				if index >= args.len || args[index].trim_space().len == 0 {
					return error('--path expects an absolute path')
				}
				options.path = args[index].trim_space()
			}
			'--branch' {
				index++
				if index >= args.len || args[index].trim_space().len == 0 {
					return error('--branch expects a branch name')
				}
				options.branch = args[index].trim_space()
			}
			'--new-branch' {
				index++
				if index >= args.len || args[index].trim_space().len == 0 {
					return error('--new-branch expects a branch name')
				}
				options.new_branch = args[index].trim_space()
			}
			'--reason' {
				index++
				if index >= args.len || args[index].trim_space().len == 0 {
					return error('--reason expects lock reason text')
				}
				options.reason = args[index].trim_space()
			}
			'--force' {
				options.force = true
			}
			'--json' {
				options.json = true
			}
			'--help', '-h' {
				return error('help')
			}
			else {
				return error('unknown worktrees option: ${arg}')
			}
		}
		index++
	}
	match options.action {
		.list {}
		.prune {}
		.add {
			if options.path.len == 0 {
				return error('worktrees add requires --path')
			}
			if options.branch.len == 0 && options.new_branch.len == 0 {
				return error('worktrees add requires --branch or --new-branch')
			}
		}
		.remove {
			if options.path.len == 0 {
				return error('worktrees remove requires --path')
			}
		}
		.lock {
			if options.path.len == 0 {
				return error('worktrees lock requires --path')
			}
		}
		.unlock {
			if options.path.len == 0 {
				return error('worktrees unlock requires --path')
			}
			if options.reason.len > 0 {
				return error('worktrees unlock does not accept --reason')
			}
		}
	}
	return options
}

fn headless_worktrees_api_error(response http.Response) string {
	decoded := json2.decode[APIError](response.body) or { return 'HTTP ${response.status_code}' }
	if decoded.error.len > 0 {
		return decoded.error
	}
	return 'HTTP ${response.status_code}'
}

fn resolve_headless_worktrees_session(port int, options HeadlessWorktreesOptions) !string {
	if options.session_id.len > 0 {
		response := headless_json_request(port, .get, '/v1/sessions/${options.session_id}',
			'', false, '')!
		if response.status_code != 200 {
			return error(headless_worktrees_api_error(response))
		}
		return options.session_id
	}
	workspace := os.real_path(options.workspace)
	if !os.is_dir(workspace) {
		return error('--workspace must resolve to an existing directory')
	}
	response := headless_json_request(port, .post, '/v1/sessions', json2.encode(SessionInput{
		title:     'Veasel worktrees'
		directory: workspace
	}), false, '')!
	if response.status_code != 200 {
		return error(headless_worktrees_api_error(response))
	}
	session := json2.decode[Session](response.body)!
	return session.id
}

fn execute_headless_worktrees_list(port int, session_id string, as_json bool) !string {
	response := headless_json_request(port, .get, '/v1/sessions/${session_id}/workspace/git/worktrees',
		'', false, '')!
	if response.status_code != 200 {
		return error(headless_worktrees_api_error(response))
	}
	if as_json {
		return response.body
	}
	catalog := json2.decode[WorkspaceGitWorktreeCatalog](response.body)!
	mut lines := []string{cap: catalog.worktrees.len + 1}
	lines << 'Git worktrees (${catalog.worktrees.len})'
	for tree in catalog.worktrees {
		kind := if tree.is_main { 'main' } else { 'linked' }
		locked_mark := if tree.locked { ' locked' } else { '' }
		missing_mark := if tree.missing { ' missing' } else { '' }
		branch := if tree.branch.len > 0 { tree.branch } else { tree.head }
		lines << '${kind}${locked_mark}${missing_mark}  ${tree.path}  ${branch}'
	}
	return lines.join('\n')
}

fn execute_headless_worktrees_prune(port int, session_id string, as_json bool) !string {
	payload := {
		'prune': json2.Any(true)
	}
	response := headless_json_request(port, .post, '/v1/sessions/${session_id}/workspace/git/worktrees',
		json2.encode(payload), false, '')!
	if response.status_code != 200 {
		return error(headless_worktrees_api_error(response))
	}
	if as_json {
		return response.body
	}
	catalog := json2.decode[WorkspaceGitWorktreeCatalog](response.body)!
	return 'Pruned git worktrees; ${catalog.worktrees.len} remain'
}

fn execute_headless_worktrees_add(port int, session_id string, options HeadlessWorktreesOptions) !string {
	mut payload := map[string]json2.Any{}
	payload['path'] = options.path
	if options.branch.len > 0 {
		payload['branch'] = options.branch
	}
	if options.new_branch.len > 0 {
		payload['new_branch'] = options.new_branch
	}
	response := headless_json_request(port, .post, '/v1/sessions/${session_id}/workspace/git/worktrees',
		json2.encode(payload), false, '')!
	if response.status_code != 200 {
		return error(headless_worktrees_api_error(response))
	}
	if options.json {
		return response.body
	}
	tree := json2.decode[WorkspaceGitWorktree](response.body)!
	return 'Added worktree ${tree.path} (${tree.branch})'
}

fn execute_headless_worktrees_remove(port int, session_id string, options HeadlessWorktreesOptions) !string {
	payload := {
		'path':  json2.Any(options.path)
		'force': json2.Any(options.force)
	}
	response := headless_json_request(port, .delete, '/v1/sessions/${session_id}/workspace/git/worktrees',
		json2.encode(payload), false, '')!
	if response.status_code != 200 {
		return error(headless_worktrees_api_error(response))
	}
	if options.json {
		return response.body
	}
	removal := json2.decode[WorkspaceGitWorktreeRemoval](response.body)!
	return 'Removed worktree ${removal.removed}'
}

fn execute_headless_worktrees_set_locked(port int, session_id string, options HeadlessWorktreesOptions,
	locked bool) !string {
	mut payload := map[string]json2.Any{}
	payload['path'] = options.path
	payload['locked'] = locked
	if locked && options.reason.len > 0 {
		payload['reason'] = options.reason
	}
	response := headless_json_request(port, .patch, '/v1/sessions/${session_id}/workspace/git/worktrees',
		json2.encode(payload), false, '')!
	if response.status_code != 200 {
		return error(headless_worktrees_api_error(response))
	}
	if options.json {
		return response.body
	}
	tree := json2.decode[WorkspaceGitWorktree](response.body)!
	if locked {
		return 'Locked worktree ${tree.path}'
	}
	return 'Unlocked worktree ${tree.path}'
}

fn execute_headless_worktrees_command(port int, args []string) {
	options := parse_headless_worktrees_args(args, os.getwd()) or {
		if err.msg() == 'help' {
			print_headless_worktrees_help()
			return
		}
		eprintln('veasel: ${err.msg()}')
		print_headless_worktrees_help()
		exit(2)
	}
	ensure_backend(port, '') or {
		eprintln('veasel: ${err.msg()}')
		exit(1)
	}
	session_id := resolve_headless_worktrees_session(port, options) or {
		eprintln('veasel: ${err.msg()}')
		exit(1)
	}
	output := match options.action {
		.list {
			execute_headless_worktrees_list(port, session_id, options.json) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
		.add {
			execute_headless_worktrees_add(port, session_id, options) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
		.remove {
			execute_headless_worktrees_remove(port, session_id, options) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
		.lock {
			execute_headless_worktrees_set_locked(port, session_id, options, true) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
		.unlock {
			execute_headless_worktrees_set_locked(port, session_id, options, false) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
		.prune {
			execute_headless_worktrees_prune(port, session_id, options.json) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
	}
	println(output)
}
