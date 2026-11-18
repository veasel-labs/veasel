module main

import os
import time

// Read-only working-tree view for a session's directory (Focus "Changes"). It answers the
// question "what did the agent change?" from the repository itself. It reuses the confined
// git runner from workspace_git.v and never writes: no stage, commit, or checkout here.

const max_workspace_git_diff_bytes = 262_144
const max_workspace_git_changes = 500
const max_workspace_git_status_bytes = 1_048_576

pub struct WorkspaceGitChange {
pub:
	path      string
	index     string // porcelain X column: staged state, ' ' when unchanged
	worktree  string // porcelain Y column: working-tree state, ' ' when unchanged
	untracked bool
}

pub struct WorkspaceGitChanges {
pub:
	branch    string @[omitempty]
	changes   []WorkspaceGitChange
	truncated bool
}

pub struct WorkspaceGitDiff {
pub:
	path      string
	staged    bool
	diff      string
	truncated bool
}

const workspace_git_untrusted_timeout = 10 * time.second
const workspace_git_blocked_config_prefixes = ['filter.', 'include.', 'includeif.']

// A repository is untrusted input: git status/diff run whatever its own .git/config configures
// (core.fsmonitor, diff.external, textconv, clean filters, included files). Every invocation here
//   - overrides those settings on the command line and in GIT_CONFIG_* (which outrank repo config),
//   - ignores the user's and system config and never prompts or takes optional locks,
//   - receives a minimal environment, runs with cwd = the confined repository top level,
//   - has a hard timeout and a bounded read, and
// the repository is refused outright when its local config defines filters or includes (git has no
// switch that turns off clean/smudge filters, and an include can smuggle one in).
fn workspace_git_hardened_config() []string {
	return ['core.fsmonitor=false', 'core.pager=cat', 'diff.external=', 'core.hooksPath=/dev/null',
		'protocol.ext.allow=never', 'core.sshCommand=false', 'core.untrackedCache=false',
		'status.submoduleSummary=false', 'diff.submodule=short']
}

fn workspace_git_untrusted_env() map[string]string {
	null_device := $if windows { 'NUL' } $else { '/dev/null' }
	config := workspace_git_hardened_config()
	mut env := {
		'PATH':                os.getenv('PATH')
		'LC_ALL':              'C'
		'GIT_CONFIG_NOSYSTEM': '1'
		'GIT_CONFIG_GLOBAL':   null_device
		'GIT_CONFIG_SYSTEM':   null_device
		'GIT_OPTIONAL_LOCKS':  '0'
		'GIT_TERMINAL_PROMPT': '0'
		'GIT_PAGER':           'cat'
		'GIT_EXTERNAL_DIFF':   ''
		'GIT_ASKPASS':         'false'
		'GIT_CONFIG_COUNT':    '${config.len}'
	}
	for index, entry in config {
		env['GIT_CONFIG_KEY_${index}'] = entry.all_before('=')
		env['GIT_CONFIG_VALUE_${index}'] = entry.all_after('=')
	}
	$if windows {
		env['SystemRoot'] = os.getenv('SystemRoot')
	}
	return env
}

// workspace_git_confined_root returns the real path of a session directory that is itself the
// repository top level with a real (non-symlink) .git directory, else an error.
fn workspace_git_confined_root(directory string) !string {
	if directory.len == 0 || !os.is_dir(directory) {
		return error('session directory is not available')
	}
	root := os.real_path(directory)
	dot_git := os.join_path(root, '.git')
	if os.is_link(dot_git) || !os.is_dir(dot_git) {
		return error('the session directory must be a git repository top level with its own .git directory')
	}
	return root
}

fn workspace_git_refuse_command_config(root string) ! {
	config := os.read_file(os.join_path(root, '.git', 'config')) or { '' }
	mut section := ''
	for raw in config.split_into_lines() {
		line := raw.trim_space().to_lower()
		if line.starts_with('[') {
			section = line.trim_left('[').all_before(']').all_before(' ').all_before('"')
			for prefix in workspace_git_blocked_config_prefixes {
				if (section + '.').starts_with(prefix) {
					return error('this repository configures git filters or includes that run commands; open its terminal to review changes')
				}
			}
		}
	}
}

// run_untrusted_git runs git for a confined repository root and returns stdout, capped at max_bytes
// (the bool reports truncation). It never reads unbounded output and kills a slow process.
fn run_untrusted_git(root string, args []string, max_bytes int) !(string, bool) {
	git := os.find_abs_path_of_executable('git') or { return error('git executable is not available') }
	mut full := []string{}
	for entry in workspace_git_hardened_config() {
		full << '-c'
		full << entry
	}
	full << args
	mut process := os.new_process(git)
	process.set_args(full)
	process.set_work_folder(root)
	process.set_environment(workspace_git_untrusted_env())
	process.set_redirect_stdio()
	process.run()
	started := time.now()
	mut out := []u8{}
	mut truncated := false
	for process.is_alive() || process.is_pending(.stdout) {
		if time.since(started) > workspace_git_untrusted_timeout {
			process.signal_kill()
			process.close()
			return error('git timed out')
		}
		if process.is_pending(.stdout) {
			chunk := process.stdout_read()
			if chunk.len > 0 {
				out << chunk.bytes()
			}
			if out.len > max_bytes {
				truncated = true
				process.signal_kill()
				break
			}
			continue
		}
		time.sleep(5 * time.millisecond)
	}
	process.wait()
	code := process.code
	process.close()
	if truncated {
		return out[..max_bytes].bytestr(), true
	}
	if code != 0 {
		return error('git could not read this repository')
	}
	return out.bytestr(), false
}

// workspace_git_changes lists changed, staged and untracked paths with plain `git status`.
fn workspace_git_changes(directory string) !WorkspaceGitChanges {
	root := workspace_git_confined_root(directory)!
	workspace_git_refuse_command_config(root)!
	out, cut := run_untrusted_git(root, ['status', '--porcelain=v1', '-z', '--branch', '--no-renames',
		'--untracked-files=all'], max_workspace_git_status_bytes)!
	mut branch := ''
	mut changes := []WorkspaceGitChange{}
	mut truncated := cut
	for entry in out.split('\0') {
		if entry.len == 0 {
			continue
		}
		if entry.starts_with('## ') {
			branch = entry[3..].all_before('...').all_before(' ')
			continue
		}
		if entry.len < 4 {
			continue
		}
		if changes.len >= max_workspace_git_changes {
			truncated = true
			break
		}
		changes << WorkspaceGitChange{
			path:      entry[3..]
			index:     entry[..1]
			worktree:  entry[1..2]
			untracked: entry.starts_with('??')
		}
	}
	return WorkspaceGitChanges{
		branch:    branch
		changes:   changes
		truncated: truncated
	}
}

fn validate_workspace_git_diff_path(path string) !string {
	if path.len == 0 || path.len > 4_096 || path.starts_with('-') || os.is_abs_path(path)
		|| path.contains('\x00') {
		return error('diff path must be a non-empty relative path')
	}
	for segment in path.replace('\\', '/').split('/') {
		if segment == '..' {
			return error('diff path must not leave the selected root')
		}
	}
	return path
}

// workspace_git_diff returns the unified diff of one path, never running external diff
// drivers or text converters, truncated (with a marker) at max_workspace_git_diff_bytes.
fn workspace_git_diff(directory string, path string, staged bool) !WorkspaceGitDiff {
	safe := validate_workspace_git_diff_path(path)!
	root := workspace_git_confined_root(directory)!
	workspace_git_refuse_command_config(root)!
	mut args := ['diff', '--no-ext-diff', '--no-textconv', '--no-color', '--no-renames']
	if staged {
		args << '--cached'
	}
	args << '--'
	args << safe
	out, cut := run_untrusted_git(root, args, max_workspace_git_diff_bytes)!
	return WorkspaceGitDiff{
		path:      safe
		staged:    staged
		diff:      if cut { out + '\n[diff truncated]\n' } else { out }
		truncated: cut
	}
}
