module main

// Installed-CLI provider registry for #691/#638: declarative capability
// data for the dual provider plane (ADR-0001 decision 2). Capability
// fields Hornero/Veasel have not verified against a live CLI are recorded
// as unverified rather than guessed; auth detection is file-presence
// only and credential contents are never read. This registry is data for
// the pre-launch capability validation (#638): selecting a provider whose
// permission mode or protocol is unsupported must fail closed.

pub struct ProviderCliSpec {
pub:
	id                      string // claude-code|codex|opencode|muse
	name                    string
	exec                    string
	protocol                string // stream-json|app-server|acp|unknown
	auth_probe_path         string // '~/...' presence-only probe, '' if none
	permission_modes        []string
	session_resume_verified bool
	usage_reporting         string // adapter-reported|not-published|unknown
}

pub fn provider_cli_registry() []ProviderCliSpec {
	return [
		ProviderCliSpec{
			id:                      'claude-code'
			name:                    'Claude Code'
			exec:                    'claude'
			protocol:                'stream-json'
			auth_probe_path:         '~/.claude/.credentials.json'
			permission_modes:        ['ask', 'accept-edits', 'plan', 'bypass']
			session_resume_verified: true             // --resume, measured claude 2.1.322 in agent-toolkit
			usage_reporting:         'adapter-reported' // result frame usage + total_cost_usd (session-cumulative)
		},
		ProviderCliSpec{
			id:                      'codex'
			name:                    'OpenAI Codex'
			exec:                    'codex'
			protocol:                'app-server'
			auth_probe_path:         '~/.codex/auth.json'
			permission_modes:        ['ask', 'accept-edits', 'plan', 'bypass']
			session_resume_verified: true          // thread/resume, measured codex-cli 0.167.2
			usage_reporting:         'not-published' // tokenUsage last/total are not per-turn spend
		},
		ProviderCliSpec{
			id:                      'opencode'
			name:                    'OpenCode'
			exec:                    'opencode'
			protocol:                'acp'
			auth_probe_path:         '~/.local/share/opencode/auth.json'
			permission_modes:        ['ask']          // ACP approvals are ask-only; see opencode_permission_mode_supported
			session_resume_verified: true             // session/load with safe session id
			usage_reporting:         'adapter-reported' // prompt result input/output tokens; cost never reported
		},
		ProviderCliSpec{
			id:                      'muse'
			name:                    'Muse Code'
			exec:                    'muse'
			protocol:                'unknown' // MSP wire protocol not verified as ACP/MCP
			auth_probe_path:         '~/.config/muse/auth.json'
			permission_modes:        ['ask']
			session_resume_verified: false
			usage_reporting:         'unknown'
		},
	]
}

pub fn provider_cli_by_id(id string) ?ProviderCliSpec {
	for spec in provider_cli_registry() {
		if spec.id == id {
			return spec
		}
	}
	return none
}

// validate_provider_cli_launch is the #638 pre-launch gate: unknown
// provider, unverified protocol, or an unsupported permission mode all
// fail closed with a reason the caller can surface verbatim.
pub fn validate_provider_cli_launch(id string, permission_mode string) !ProviderCliSpec {
	spec := provider_cli_by_id(id) or {
		return error('unknown installed-CLI provider: ${id}')
	}
	if spec.protocol == 'unknown' {
		return error('${spec.name} protocol is not verified; refusing to launch')
	}
	if permission_mode !in spec.permission_modes {
		return error('${spec.name} does not support permission mode "${permission_mode}"')
	}
	return spec
}
