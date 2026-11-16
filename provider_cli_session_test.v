module main

import os

// E2E against the scripted fake CLI copied verbatim in PR #697
// (tests/focus_reference/testing/fake-claude.mjs, from
// agent-toolkit@ac2cd125). Skips only when node is unavailable, so CI
// without node stays honest instead of silently passing.

fn node_available() bool {
	result := os.execute('node --version')
	return result.exit_code == 0
}

fn test_run_claude_cli_turn_against_fake_fixture() {
	if !node_available() {
		eprintln('skip: node unavailable for fake-claude fixture')
		return
	}
	fixture := os.join_path('tests', 'focus_reference', 'testing', 'fake-claude.mjs')
	if !os.exists(fixture) {
		eprintln('skip: fake-claude fixture not present (lands with PR #697)')
		return
	}
	// os.new_process does not do PATH lookup for relative script paths and
	// does not split command strings, so spawn node with the fixture as an
	// argument through a tiny wrapper: run_claude_cli_turn takes the exec,
	// so point it at node and let claude_cli_args be replaced by using the
	// fixture via a shim executable.
	shim := os.join_path(os.temp_dir(), 'veasel-fake-claude-test.sh')
	os.write_file(shim, '#!/bin/sh\nexec node "${fixture}" "\$@"\n') or { panic(err) }
	os.chmod(shim, 0o755) or { panic(err) }
	defer {
		os.rm(shim) or {}
	}
	turn := run_claude_cli_turn(shim, os.getwd(), 'ask', '', 'hello', 30_000) or {
		panic(err)
	}
	assert turn.outcome == 'completed'
	assert turn.session_id == 'sess-fake-1'
	assert turn.usage_reported
	assert turn.usage.input_tokens == 10
	assert turn.usage.output_tokens == 5
	assert turn.text == 'echo:hello'
}

fn test_run_claude_cli_turn_denies_approvals_fail_closed() {
	if !node_available() {
		return
	}
	fixture := os.join_path('tests', 'focus_reference', 'testing', 'fake-claude.mjs')
	if !os.exists(fixture) {
		return
	}
	shim := os.join_path(os.temp_dir(), 'veasel-fake-claude-test2.sh')
	os.write_file(shim, '#!/bin/sh\nexec node "${fixture}" "\$@"\n') or { panic(err) }
	os.chmod(shim, 0o755) or { panic(err) }
	defer {
		os.rm(shim) or {}
	}
	turn := run_claude_cli_turn(shim, os.getwd(), 'ask', '', 'please edit the file',
		30_000) or { panic(err) }
	assert turn.approvals_denied >= 1 // never auto-approved
	assert turn.outcome == 'completed' // fake completes after denial
}
