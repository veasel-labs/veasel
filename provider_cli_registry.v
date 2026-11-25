module main

// Installed-CLI provider registry for #691/#638: declarative capability
// data for the dual provider plane (ADR-0001 decision 2). Capability
// fields Hornero/Veasel have not verified against a live CLI are recorded
// as unverified rather than guessed; credential file presence is only a
// hint, and native authentication is verified only for CLIs with a supported
// status contract. Credential contents are never read. This registry is data for
// the pre-launch capability validation (#638): selecting a provider whose
// permission mode or protocol is unsupported must fail closed.

pub struct ProviderCliSpec {
pub:
	id                      string // claude-code|codex|opencode|muse
	name                    string
	exec                    string
	protocol                string   // stream-json|app-server|acp|unknown
	auth_probe_path         string   // '~/...' presence hint, '' if none; contents are never read
	auth_status_args        []string // provider-owned, non-mutating local auth check
	auth_status_kind        string   // claude-json|codex-text|'' when unsupported
	permission_modes        []string
	session_resume_verified bool
	usage_reporting         string // adapter-reported|not-published|unknown
	launch_blocked_reason   string // non-empty until protocol prerequisites are verified
}

pub fn provider_cli_registry() []ProviderCliSpec {
	return [
		ProviderCliSpec{
			id:                      'claude-code'
			name:                    'Claude Code'
			exec:                    'claude'
			protocol:                'stream-json'
			auth_probe_path:         '~/.claude/.credentials.json'
			auth_status_args:        ['auth', 'status', '--json']
			auth_status_kind:        'claude-json'
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
			auth_status_args:        ['login', 'status']
			auth_status_kind:        'codex-text'
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
			protocol:                'acp' // `muse acp`, verified live against Muse Code 1.4.20 (initialize + session/new)
			auth_probe_path:         '~/.config/muse/auth.json'
			permission_modes:        ['ask'] // runner forces mode=onRequest; Muse defaults sessions to allowAll
			session_resume_verified: false   // loadSession advertised live, resume path not yet exercised
			usage_reporting:         'unknown' // prompt-result usage not yet measured for Muse
		},
		ProviderCliSpec{
			id:                      'cursor-agent'
			name:                    'Cursor Agent'
			exec:                    'cursor-agent'
			protocol:                'acp' // initialize observed on cursor-agent 2026.09.15-d2fe57e
			auth_status_args:        ['status', '--format', 'json']
			auth_status_kind:        'cursor-json' // isAuthenticated observed; no credential contents read
			permission_modes:        []          // disabled until Cursor's ACP permission options are verified
			session_resume_verified: false
			usage_reporting:         'unknown'
			launch_blocked_reason:   'Cursor Agent is discovered but not launchable: Veasel has not implemented the required ACP authenticate(cursor_login) step or verified Cursor permission responses. Continue with the configured model provider or a verified CLI runner; authenticating Cursor with its own CLI does not enable it here.'
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
	if spec.launch_blocked_reason.len > 0 {
		return error(spec.launch_blocked_reason)
	}
	if permission_mode !in spec.permission_modes {
		return error('${spec.name} does not support permission mode "${permission_mode}"')
	}
	return spec
}
