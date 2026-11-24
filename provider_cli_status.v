module main

import os
import json2
import time

const provider_cli_status_timeout_ms = 2_000
const provider_cli_status_output_limit = 16_384

// Installed-CLI status for #691. Sign-in is verified only when a provider's
// own documented, non-mutating status command returns a recognized result.
// Credential contents, account identifiers, and raw command output are never
// returned or logged.

pub struct ProviderCliStatus {
pub:
	id                      string
	name                    string
	exec                    string
	protocol                string
	installed               bool
	version                 string
	auth_probe_present      bool
	auth_state              string
	auth_method             string
	account_mode            string
	auth_error              string
	permission_modes        []string
	session_resume_verified bool
	usage_reporting         string
}

struct ProviderCliStatusCommandResult {
	code   int
	stdout string
}

struct ClaudeAuthStatusResponse {
	logged_in         ?bool @[json: 'loggedIn']
	auth_method       string @[json: 'authMethod']
	subscription_type string @[json: 'subscriptionType']
}

struct ProviderCliAuthResult {
	state        string
	method       string
	account_mode string
	error        string
}

pub fn provider_cli_status_from_probe(spec ProviderCliSpec, installed_path string,
	version string, auth_probe_present bool) ProviderCliStatus {
	return provider_cli_status_with_auth(spec, installed_path, version, auth_probe_present, ProviderCliAuthResult{})
}

fn provider_cli_status_with_auth(spec ProviderCliSpec, installed_path string, version string,
	auth_probe_present bool, auth ProviderCliAuthResult) ProviderCliStatus {
	state := if auth.state.len > 0 {
		auth.state
	} else if spec.auth_probe_path.len == 0 {
		'unknown'
	} else if auth_probe_present {
		'probe-present'
	} else {
		'probe-missing'
	}
	return ProviderCliStatus{
		id: spec.id
		name: spec.name
		exec: spec.exec
		protocol: spec.protocol
		installed: installed_path.len > 0
		version: version.trim_space()
		auth_probe_present: auth_probe_present
		auth_state: state
		auth_method: auth.method
		account_mode: auth.account_mode
		auth_error: auth.error
		permission_modes: spec.permission_modes
		session_resume_verified: spec.session_resume_verified
		usage_reporting: spec.usage_reporting
	}
}

fn provider_cli_verified_account_mode(value string) string {
	normalized := value.trim_space().to_lower()
	return if normalized in ['free', 'pro', 'max', 'team', 'enterprise'] {
		normalized
	} else {
		''
	}
}

fn provider_cli_auth_result(spec ProviderCliSpec, exit_code int, output string) ProviderCliAuthResult {
	if exit_code != 0 {
		return ProviderCliAuthResult{
			error: 'status-command-failed'
		}
	}
	match spec.auth_status_kind {
		'claude-json' {
			response := json2.decode[ClaudeAuthStatusResponse](output) or {
				return ProviderCliAuthResult{
					error: 'unrecognized-status-response'
				}
			}
			if logged_in := response.logged_in {
				if !logged_in {
					return ProviderCliAuthResult{
						state: 'signed-out'
					}
				}
				method := match response.auth_method.trim_space().to_lower() {
					'claude.ai' { 'claude.ai' }
					'console' { 'console' }
					else { '' }
				}
				return ProviderCliAuthResult{
					state: 'verified'
					method: method
					account_mode: provider_cli_verified_account_mode(response.subscription_type)
				}
			}
			return ProviderCliAuthResult{
				error: 'unrecognized-status-response'
			}
		}
		'codex-text' {
			line := output.trim_space().to_lower()
			if line == 'not logged in' || line.starts_with('not logged in ') {
				return ProviderCliAuthResult{
					state: 'signed-out'
				}
			}
			if line.starts_with('logged in using chatgpt') {
				return ProviderCliAuthResult{
					state: 'verified'
					method: 'chatgpt'
				}
			}
			if line.starts_with('logged in using api key') {
				return ProviderCliAuthResult{
					state: 'verified'
					method: 'api-key'
				}
			}
			return ProviderCliAuthResult{
				error: 'unrecognized-status-response'
			}
		}
		else {
			return ProviderCliAuthResult{
				error: 'unsupported-status-command'
			}
		}
	}
}

// Run only the literal provider-owned status argv in the registry. It has no
// shell, no prompt input, a strict deadline/output cap, and kills the whole
// process group on timeout. Stderr and unrecognized stdout are discarded.
fn run_provider_cli_status_command(executable string, args []string) !ProviderCliStatusCommandResult {
	mut process := os.new_process(executable)
	process.set_args(args)
	process.set_redirect_stdio()
	process.use_pgroup = true
	process.run()
	if process.status != .running {
		process.close()
		return error('unable to start status command')
	}
	mut closed := false
	defer {
		if !closed {
			cli_terminate_process(mut process)
		}
	}
	if process.stdio_fd.len > 0 {
		os.fd_close(process.stdio_fd[0])
	}
	started := time.now()
	mut output := ''
	for process.is_alive() {
		if process.is_pending(.stdout) {
			output += process.stdout_read()
			if output.len > provider_cli_status_output_limit {
				return error('status command output limit exceeded')
			}
		}
		if process.is_pending(.stderr) {
			_ = process.stderr_read()
		}
		if time.since(started).milliseconds() > provider_cli_status_timeout_ms {
			return error('status command timed out')
		}
		time.sleep(10 * time.millisecond)
	}
	for process.is_pending(.stdout) {
		output += process.stdout_read()
		if output.len > provider_cli_status_output_limit {
			return error('status command output limit exceeded')
		}
	}
	for process.is_pending(.stderr) {
		_ = process.stderr_read()
	}
	process.wait()
	code := process.code
	process.close()
	closed = true
	if output.len > provider_cli_status_output_limit {
		return error('status command output limit exceeded')
	}
	return ProviderCliStatusCommandResult{
		code: code
		stdout: output
	}
}

fn provider_cli_probe(spec ProviderCliSpec) ProviderCliStatus {
	installed_path := os.find_abs_path_of_executable(spec.exec) or { '' }
	mut version := ''
	if installed_path.len > 0 {
		result := run_provider_cli_status_command(installed_path, ['--version']) or {
			ProviderCliStatusCommandResult{}
		}
		if result.code == 0 {
			lines := result.stdout.split_into_lines()
			if lines.len > 0 {
				version = lines[0]
			}
		}
	}
	mut auth_present := false
	if spec.auth_probe_path.len > 0 {
		probe := spec.auth_probe_path.replace_once('~/', os.home_dir() + '/')
		auth_present = os.is_file(probe)
	}
	mut auth := ProviderCliAuthResult{}
	if installed_path.len > 0 && spec.auth_status_args.len > 0 && spec.auth_status_kind.len > 0 {
		result := run_provider_cli_status_command(installed_path, spec.auth_status_args) or {
			auth = ProviderCliAuthResult{
				error: if err.msg().contains('timed out') {
					'status-command-timeout'
				} else {
					'status-command-failed'
				}
			}
			return provider_cli_status_with_auth(spec, installed_path, version, auth_present, auth)
		}
		auth = provider_cli_auth_result(spec, result.code, result.stdout)
	}
	return provider_cli_status_with_auth(spec, installed_path, version, auth_present, auth)
}

pub fn provider_cli_statuses() []ProviderCliStatus {
	return provider_cli_registry().map(provider_cli_probe(it))
}
