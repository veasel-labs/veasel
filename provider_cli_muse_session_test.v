module main

import os

// E2E against Veasel's authored fake Muse ACP host
// (testing/fake-muse-acp.mjs), which mirrors the live-verified wire
// behavior of Muse Code 1.4.20: session/new defaults mode to
// allowAll and the fixture refuses any prompt until the runner forces
// mode=onRequest. Skips only when node is unavailable.

fn muse_node_available() bool {
	result := os.execute('node --version')
	return result.exit_code == 0
}

fn muse_fixture_shim() (string, bool) {
	if !muse_node_available() {
		eprintln('skip: node unavailable for fake-muse fixture')
		return '', false
	}
	fixture := os.join_path('testing', 'fake-muse-acp.mjs')
	if !os.exists(fixture) {
		eprintln('skip: fake-muse fixture not present')
		return '', false
	}
	shim := os.join_path(os.temp_dir(), 'veasel-fake-muse-test.sh')
	os.write_file(shim, '#!/bin/sh\nexec node "${os.abs_path(fixture)}" "$@"\n') or {
		panic(err)
	}
	os.chmod(shim, 0o755) or { panic(err) }
	return shim, true
}

fn test_run_muse_cli_turn_forces_ask_mode() {
	shim, ok := muse_fixture_shim()
	if !ok {
		return
	}
	defer { os.rm(shim) or {} }
	// The fixture errors any prompt not preceded by mode=onRequest, so a
	// completed turn proves the runner never ran under allowAll.
	turn := run_muse_cli_turn(shim, os.getwd(), '', 'hello', 30_000,
		ignore_provider_text_delta, deny_all_cli_approvals) or { panic(err) }
	assert turn.outcome == 'completed'
	assert turn.session_id == 'muse-fake-session-1'
	assert turn.text == 'MUSE_OK'
	assert !turn.usage_reported
}

fn test_run_muse_cli_turn_denies_permission_fail_closed() {
	shim, ok := muse_fixture_shim()
	if !ok {
		return
	}
	defer { os.rm(shim) or {} }
	turn := run_muse_cli_turn(shim, os.getwd(), '', 'approval', 30_000,
		ignore_provider_text_delta, deny_all_cli_approvals) or { panic(err) }
	assert turn.outcome == 'completed'
	assert turn.approvals_denied == 1
	assert turn.approvals_approved == 0
	assert turn.text.contains('Not allowed.')
}

fn test_muse_registry_is_acp_ask_only() {
	spec := validate_provider_cli_launch('muse', 'ask') or { panic(err) }
	assert spec.protocol == 'acp'
	_ := validate_provider_cli_launch('muse', 'bypass') or {
		assert err.msg().contains('does not support permission mode')
		return
	}
	panic('muse bypass must fail closed')
}
