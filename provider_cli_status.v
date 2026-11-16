module main

import os

// Installed-CLI provider status for #691: honest, presence-only facts for
// settings/GUI consumers. `installed` and `version` come from PATH lookup
// and the binary's own --version output; `auth_state` is ONLY a file
// presence probe (registry `auth_probe_path`) — credential contents are
// never read and presence is never reported as a verified sign-in, so
// `auth_state` is 'probe-present'|'probe-missing'|'unknown', never
// 'ready'.

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
	permission_modes        []string
	session_resume_verified bool
	usage_reporting         string
}

pub fn provider_cli_status_from_probe(spec ProviderCliSpec, installed_path string,
	version string, auth_probe_present bool) ProviderCliStatus {
	return ProviderCliStatus{
		id:                      spec.id
		name:                    spec.name
		exec:                    spec.exec
		protocol:                spec.protocol
		installed:               installed_path.len > 0
		version:                 version.trim_space()
		auth_probe_present:      auth_probe_present
		auth_state:              if spec.auth_probe_path.len == 0 {
			'unknown'
		} else if auth_probe_present {
			'probe-present'
		} else {
			'probe-missing'
		}
		permission_modes:        spec.permission_modes
		session_resume_verified: spec.session_resume_verified
		usage_reporting:         spec.usage_reporting
	}
}

fn provider_cli_probe(spec ProviderCliSpec) ProviderCliStatus {
	installed_path := os.find_abs_path_of_executable(spec.exec) or { '' }
	mut version := ''
	if installed_path.len > 0 {
		result := os.exec([spec.exec, '--version'])
		if result.exit_code == 0 {
			lines := result.output.split_into_lines()
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
	return provider_cli_status_from_probe(spec, installed_path, version, auth_present)
}

pub fn provider_cli_statuses() []ProviderCliStatus {
	return provider_cli_registry().map(provider_cli_probe(it))
}
