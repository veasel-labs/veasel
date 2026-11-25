module main

import os
import time

const max_goal_repositories_to_verify = 8
const max_goal_tasks_to_verify = 64
const max_goal_paths_per_task_to_verify = 64
const max_goal_total_paths_to_verify = 128
const max_goal_scope_checks_to_verify = 512
const max_goal_git_output_bytes = 16 * 1024
const max_goal_preflight_attempts = 128
const max_goal_preflight_provider_turns = 128
const max_goal_preflight_wall_seconds = 86_400

struct GoalVerifiedCheckout {
	owner string
	name  string
	path  string
}

struct GoalPreflightRepository {
	owner             string
	name              string
	identity_verified bool
	tasks_checked     int
}

struct GoalPreflightDiagnostic {
	code       string
	message    string
	repository string
}

struct GoalPreflightReport {
mut:
	goal_id             string
	checkouts_validated bool
	repositories        []GoalPreflightRepository
	diagnostics         []GoalPreflightDiagnostic
}

struct GoalCheckoutInspection {
mut:
	checkouts map[string]GoalVerifiedCheckout
	report    GoalPreflightReport
}

// verify_goal_checkouts revalidates local identity immediately before worker
// checkout creation. It does not verify runner or verifier implementations.
fn verify_goal_checkouts(goal GoalAdmission) !map[string]GoalVerifiedCheckout {
	inspection := inspect_goal_checkouts(goal)
	if !inspection.report.checkouts_validated {
		return error(inspection.report.diagnostics[0].message)
	}
	return inspection.checkouts
}

fn inspect_goal_checkouts(goal GoalAdmission) GoalCheckoutInspection {
	mut inspection := GoalCheckoutInspection{
		checkouts: map[string]GoalVerifiedCheckout{}
		report:    GoalPreflightReport{
			goal_id: goal.id
		}
	}
	validate_goal_admission(goal) or {
		inspection.report.diagnostics << GoalPreflightDiagnostic{
			code:    'manifest_invalid'
			message: err.msg()
		}
		return inspection
	}
	validate_goal_preflight_deadline(goal) or {
		inspection.report.diagnostics << GoalPreflightDiagnostic{
			code:    'deadline_elapsed'
			message: err.msg()
		}
		return inspection
	}
	validate_goal_preflight_budget(goal) or {
		inspection.report.diagnostics << GoalPreflightDiagnostic{
			code:    'budget_limit'
			message: err.msg()
		}
		return inspection
	}
	if goal.authorized_repositories.len > max_goal_repositories_to_verify
		|| goal.tasks.len > max_goal_tasks_to_verify {
		inspection.report.diagnostics << GoalPreflightDiagnostic{
			code:    'verification_limit'
			message: 'Goal exceeds the local checkout verification limit'
		}
		return inspection
	}
	mut scope_checks := 0
	mut path_checks := 0
	for task in goal.tasks {
		for path in task.paths {
			path_checks++
			scope_checks += path.split('/').len
			if path.len > 4096 || path_checks > max_goal_total_paths_to_verify
				|| scope_checks > max_goal_scope_checks_to_verify {
				inspection.report.diagnostics << GoalPreflightDiagnostic{
					code:    'verification_limit'
					message: 'Goal exceeds the task path verification limit'
				}
				return inspection
			}
		}
	}
	for repository in goal.authorized_repositories {
		mut tasks := []GoalTask{}
		for task in goal.tasks {
			if task.repository.to_lower() == '${repository.owner}/${repository.name}'.to_lower() {
				tasks << task
			}
		}
		if tasks.len == 0 {
			inspection.report.repositories << GoalPreflightRepository{
				owner: repository.owner
				name:  repository.name
			}
			inspection.report.diagnostics << GoalPreflightDiagnostic{
				code:       'repository_has_no_tasks'
				message:    'Every authorized repository must have at least one task'
				repository: '${repository.owner}/${repository.name}'
			}
			continue
		}
		key := '${repository.owner}/${repository.name}'.to_lower()
		checkout := verify_goal_repository_checkout(repository, tasks) or {
			inspection.report.repositories << GoalPreflightRepository{
				owner: repository.owner
				name:  repository.name
			}
			inspection.report.diagnostics << GoalPreflightDiagnostic{
				code:       'repository_not_ready'
				message:    err.msg()
				repository: '${repository.owner}/${repository.name}'
			}
			continue
		}
		inspection.checkouts[key] = checkout
		inspection.report.repositories << GoalPreflightRepository{
			owner:             repository.owner
			name:              repository.name
			identity_verified: true
			tasks_checked:     tasks.len
		}
	}
	inspection.report.checkouts_validated = inspection.report.diagnostics.len == 0
	return inspection
}

fn validate_goal_preflight_deadline(goal GoalAdmission) ! {
	deadline := time.parse_rfc3339(goal.deadline) or {
		return error('Goal deadline could not be parsed')
	}
	if deadline <= time.now() {
		return error('Goal deadline has elapsed')
	}
}

fn validate_goal_preflight_budget(goal GoalAdmission) ! {
	if goal.budget.max_attempts > max_goal_preflight_attempts
		|| goal.budget.provider_turns > max_goal_preflight_provider_turns
		|| goal.budget.wall_seconds > max_goal_preflight_wall_seconds {
		return error('Goal budget exceeds the local preflight policy ceiling')
	}
}

fn verify_goal_repository_checkout(repository GoalRepository, tasks []GoalTask) !GoalVerifiedCheckout {
	if repository.path.len > 4096 || workspace_has_hidden_controls(repository.path)
		|| !os.is_abs_path(repository.path) || !os.is_dir(repository.path) {
		return error('Authorized repository path must be an existing absolute checkout root')
	}
	canonical_path := os.real_path(repository.path)
	if repository.path.trim_right(os.path_separator) != canonical_path.trim_right(os.path_separator) {
		return error('Authorized repository path must be canonical and must not traverse symlinks')
	}
	root_output := run_goal_git_command_output(canonical_path,
		['--no-replace-objects', 'rev-parse', '--show-toplevel'], max_goal_git_output_bytes) or {
		return error('Authorized repository path is not a readable Git checkout')
	}
	root_value := root_output.trim_space()
	if root_value.len == 0 {
		return error('Authorized repository path is not a readable Git checkout')
	}
	git_root := os.real_path(root_value)
	if git_root != canonical_path {
		return error('Authorized repository path must name the Git checkout root')
	}
	verify_goal_remote_identity(canonical_path, repository)!
	mut checked_commits := map[string]bool{}
	for task in tasks {
		if task.paths.len == 0 || task.paths.len > max_goal_paths_per_task_to_verify {
			return error('Goal task has an invalid number of scoped paths')
		}
		if !valid_goal_sha(task.base_sha) {
			return error('Goal task must pin a full Git commit ID')
		}
		if !checked_commits[task.base_sha] {
			resolved := run_goal_git_command_output(canonical_path,
				['--no-replace-objects', 'rev-parse', '--verify', '--end-of-options',
					'${task.base_sha}^{commit}'],
				max_goal_git_output_bytes) or {
				return error('Goal task base commit does not exist in the authorized repository')
			}
			if resolved.trim_space() != task.base_sha {
				return error('Goal task base commit did not resolve to the exact full commit ID')
			}
			checked_commits[task.base_sha] = true
		}
		for path in task.paths {
			verify_goal_task_scope(canonical_path, task.base_sha, path)!
		}
	}
	return GoalVerifiedCheckout{
		owner: repository.owner
		name:  repository.name
		path:  canonical_path
	}
}

fn verify_goal_remote_identity(root string, repository GoalRepository) ! {
	raw_fetch_urls := run_goal_git_command_output(root,
		['--no-replace-objects', 'config', '--local', '--no-includes', '--get-all', 'remote.origin.url'], max_goal_git_output_bytes) or {
		return error('Authorized repository must have a GitHub origin remote')
	}
	raw_push_urls := run_goal_git_command_output(root,
		['--no-replace-objects', 'config', '--local', '--no-includes', '--get-all',
			'remote.origin.pushurl'], max_goal_git_output_bytes) or { raw_fetch_urls }
	verify_goal_remote_urls(raw_fetch_urls, repository)!
	verify_goal_remote_urls(raw_push_urls, repository)!
	effective_fetch_urls := run_goal_git_command_output(root,
		['--no-replace-objects', 'remote', 'get-url', '--all', 'origin'],
		max_goal_git_output_bytes) or {
		return error('Authorized repository must have a GitHub origin remote')
	}
	effective_push_urls := run_goal_git_command_output(root,
		['--no-replace-objects', 'remote', 'get-url', '--push', '--all', 'origin'],
		max_goal_git_output_bytes) or {
		return error('Authorized repository must have a GitHub origin push remote')
	}
	verify_goal_remote_urls(effective_fetch_urls, repository)!
	verify_goal_remote_urls(effective_push_urls, repository)!
}

fn run_goal_git_command_output(checkout string, args []string, max_output_bytes int) !string {
	git := os.find_abs_path_of_executable('git') or {
		return error('git executable is not available')
	}
	mut environment := workspace_git_untrusted_env()
	environment['GIT_SSH_COMMAND'] = 'false'
	environment['GIT_ALLOW_PROTOCOL'] = 'file'
	mut process := os.new_process(git)
	process.set_args(args)
	process.set_work_folder(checkout)
	process.set_environment(environment)
	process.set_redirect_stdio()
	process.run()
	if process.status != .running {
		process.close()
		return error('unable to start local Git metadata check')
	}
	started := time.now()
	mut stdout := []u8{cap: 4096}
	mut stderr_len := 0
	for process.is_alive() {
		if process.is_pending(.stdout) {
			chunk := process.stdout_read()
			if stdout.len + chunk.len > max_output_bytes {
				process.signal_kill()
				process.wait()
				process.close()
				return error('local Git metadata output exceeds its size limit')
			}
			stdout << chunk.bytes()
		}
		if process.is_pending(.stderr) {
			stderr_len += process.stderr_read().len
			if stdout.len + stderr_len > max_output_bytes {
				process.signal_kill()
				process.wait()
				process.close()
				return error('local Git metadata output exceeds its size limit')
			}
		}
		if time.since(started) > workspace_git_command_timeout {
			process.signal_kill()
			process.wait()
			process.close()
			return error('local Git metadata check timed out')
		}
		time.sleep(10 * time.millisecond)
	}
	for process.is_pending(.stdout) {
		chunk := process.stdout_read()
		if stdout.len + chunk.len > max_output_bytes {
			process.close()
			return error('local Git metadata output exceeds its size limit')
		}
		stdout << chunk.bytes()
	}
	for process.is_pending(.stderr) {
		stderr_len += process.stderr_read().len
		if stdout.len + stderr_len > max_output_bytes {
			process.close()
			return error('local Git metadata output exceeds its size limit')
		}
	}
	process.wait()
	code := process.code
	process.close()
	if code != 0 {
		return error('local Git metadata check failed')
	}
	return stdout.bytestr()
}

fn verify_goal_remote_urls(url_output string, repository GoalRepository) ! {
	urls := url_output.split_into_lines().filter(it.len > 0)
	if urls.len == 0 {
		return error('Authorized repository origin remote is missing')
	}
	for remote in urls {
		owner, name := parse_goal_github_remote(remote) or {
			return error('Authorized repository origin must point to GitHub owner/name')
		}
		if owner.to_lower() != repository.owner.to_lower() || name.to_lower() != repository.name.to_lower() {
			return error('Authorized repository GitHub owner/name does not match origin')
		}
	}
}

fn parse_goal_github_remote(remote string) !(string, string) {
	if remote.len == 0 || remote != remote.trim_space() || remote.contains_any(' \t\r\n?#') {
		return error('invalid GitHub remote')
	}
	mut path := ''
	if remote.starts_with('https://github.com/') {
		path = remote['https://github.com/'.len..]
	} else if remote.starts_with('ssh://git@github.com/') {
		path = remote['ssh://git@github.com/'.len..]
	} else if remote.starts_with('git@github.com:') {
		path = remote['git@github.com:'.len..]
	} else {
		return error('unsupported GitHub remote')
	}
	if path.ends_with('.git') {
		path = path[..path.len - 4]
	}
	parts := path.split('/')
	if parts.len != 2 || !valid_goal_id(parts[0]) || !valid_goal_id(parts[1]) {
		return error('GitHub remote must identify one owner and repository')
	}
	return parts[0], parts[1]
}

fn verify_goal_task_scope(root string, commit string, path string) ! {
	if path.len > 4096 || !valid_goal_relative_path(path) || workspace_has_hidden_controls(path) {
		return error('Goal task path must be a printable relative path')
	}
	segments := path.split('/')
	mut prefix := ''
	for index, segment in segments {
		prefix = if prefix.len == 0 { segment } else { '${prefix}/${segment}' }
		entry_output := run_goal_git_command_output(root,
			['--no-replace-objects', 'ls-tree', '-z', commit, '--', ':(literal)${prefix}'],
			max_goal_git_output_bytes) or {
			return error('Unable to inspect goal task path in its pinned commit')
		}
		if entry_output.len == 0 {
			break
		}
		entry := entry_output.split('\0')[0]
		tab := entry.index('\t') or {
			return error('Pinned Git tree entry is malformed')
		}
		metadata := entry[..tab].split(' ')
		if metadata.len < 2 {
			return error('Pinned Git tree entry is malformed')
		}
		mode := metadata[0]
		kind := metadata[1]
		if mode == '120000' {
			return error('Goal task path must not traverse a symlink in its pinned commit')
		}
		if mode == '160000' {
			return error('Goal task path must not traverse a submodule')
		}
		if index < segments.len - 1 && kind != 'tree' {
			return error('Goal task path parent is not a directory in its pinned commit')
		}
	}
	mut current := root
	for segment in segments {
		current = os.join_path(current, segment)
		if os.is_link(current) {
			return error('Goal task path must not traverse a working-tree symlink')
		}
		if !os.exists(current) {
			break
		}
		resolved := os.real_path(current)
		if !path_is_within(root, resolved) {
			return error('Goal task path escapes the authorized checkout')
		}
		current = resolved
	}
}
