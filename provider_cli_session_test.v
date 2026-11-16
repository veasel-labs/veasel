module main

import os
import time

struct StreamedSink {
pub mut:
	text string
}

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
	turn := run_claude_cli_turn(shim, os.getwd(), 'ask', '', 'hello', 30_000, ignore_provider_text_delta, deny_all_cli_approvals) or {
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
		30_000, ignore_provider_text_delta, deny_all_cli_approvals) or { panic(err) }
	assert turn.approvals_denied >= 1 // never auto-approved
	assert turn.outcome == 'completed' // fake completes after denial
}

fn test_complete_cli_provider_turn_against_fake_fixture() {
	if !node_available() {
		return
	}
	fixture := os.join_path('tests', 'focus_reference', 'testing', 'fake-claude.mjs')
	if !os.exists(fixture) {
		return
	}
	// The runner spawns spec.exec from the registry (PATH lookup), so
	// point PATH at a shim named after the real CLI for this test only.
	shim_dir := os.join_path(os.temp_dir(), 'veasel-cli-path-test')
	os.mkdir_all(shim_dir) or { panic(err) }
	shim := os.join_path(shim_dir, 'claude')
	os.write_file(shim, '#!/bin/sh\nexec node "${fixture}" "\$@"\n') or { panic(err) }
	os.chmod(shim, 0o755) or { panic(err) }
	old_path := os.getenv('PATH')
	os.setenv('PATH', shim_dir + ':' + old_path, true)
	defer {
		os.setenv('PATH', old_path, true)
		os.rm(shim) or {}
	}
	mut sink := &StreamedSink{}
	output := complete_cli_provider_turn([
		ChatMessage{
			role:    'user'
			content: 'hello'
		},
	], ModelConfig{
		provider: 'claude-code'
		model:    'default'
	}, os.getwd(), fn [mut sink] (delta string) ! {
		sink.text += delta
	}) or { panic(err) }
	streamed := sink.text
	assert output.provider == 'claude-code'
	assert output.model == 'fake-model-1' // reported by the CLI init frame
	assert output.content.contains('user: hello')
	assert output.usage.reported
	assert output.provider_attempts == 1
	assert streamed == output.content // streaming reuses the session delta path
}

fn test_cli_transcript_prompt_flattens_history() {
	prompt := cli_transcript_prompt([
		ChatMessage{
			role:    'system'
			content: 'be brief'
		},
		ChatMessage{
			role:    'user'
			content: 'hi'
		},
		ChatMessage{
			role:    'assistant'
			content: 'hello'
		},
	])
	assert prompt == 'system: be brief\n\nuser: hi\n\nassistant: hello'
	unsupported := complete_cli_provider_turn([
		ChatMessage{
			role:    'user'
			content: 'hi'
		},
	], ModelConfig{
		provider: 'muse'
		model:    'default'
	}, os.getwd(), ignore_provider_text_delta) or {
		assert err.msg().contains('not verified')
		return
	}
	panic('muse must fail closed while its protocol is unverified, got ${unsupported}')
}

fn test_cli_permission_mode_gate_rejects_unknown_mode() {
	os.setenv('VEASEL_CLI_PERMISSION_MODE', 'nonsense-mode', true)
	defer {
		os.unsetenv('VEASEL_CLI_PERMISSION_MODE')
	}
	if _ := complete_cli_provider_turn([
		ChatMessage{
			role:    'user'
			content: 'hi'
		},
	], ModelConfig{
		provider: 'claude-code'
		model:    'default'
	}, os.getwd(), ignore_provider_text_delta) {
		panic('unknown permission mode must fail closed before spawning')
	}
	// OpenCode is ask-only: accept-edits must be rejected pre-launch too.
	os.setenv('VEASEL_CLI_PERMISSION_MODE', 'accept-edits', true)
	if _ := complete_cli_provider_turn([
		ChatMessage{
			role:    'user'
			content: 'hi'
		},
	], ModelConfig{
		provider: 'opencode'
		model:    'default'
	}, os.getwd(), ignore_provider_text_delta) {
		panic('opencode accept-edits must fail closed (ask-only approvals)')
	}
}

fn test_cli_turn_deadline_already_exceeded_fails_before_launch() {
	if _ := complete_cli_provider_turn([
		ChatMessage{
			role:    'user'
			content: 'hi'
		},
	], ModelConfig{
		provider:         'claude-code'
		model:            'default'
		request_deadline: time.now().add(-1 * time.second)
	}, os.getwd(), ignore_provider_text_delta) {
		panic('expired deadline must fail before spawning the CLI')
	}
}

fn test_run_claude_cli_turn_with_explicit_approval() {
	if !node_available() {
		return
	}
	fixture := os.join_path('tests', 'focus_reference', 'testing', 'fake-claude.mjs')
	if !os.exists(fixture) {
		return
	}
	shim := os.join_path(os.temp_dir(), 'veasel-fake-claude-test3.sh')
	os.write_file(shim, '#!/bin/sh\nexec node "${fixture}" "\$@"\n') or { panic(err) }
	os.chmod(shim, 0o755) or { panic(err) }
	defer {
		os.rm(shim) or {}
	}
	turn := run_claude_cli_turn(shim, os.getwd(), 'ask', '', 'please edit the file',
		30_000, ignore_provider_text_delta, fn (_ string, tool_name string, _ string) bool {
			return tool_name == 'Edit'
		}) or { panic(err) }
	assert turn.approvals_approved == 1
	assert turn.approvals_denied == 0
	assert turn.text.contains('Fixed.')
}
