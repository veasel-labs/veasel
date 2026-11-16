module main

import os

fn test_cli_resume_store_roundtrip_and_safety() {
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{
		title: 'resume'
	}) or { panic(err) }
	assert store.get_cli_resume_id(session.id, 'claude-code') == ''
	store.set_cli_resume_id(session.id, 'claude-code', 'sess-abc_1') or { panic(err) }
	assert store.get_cli_resume_id(session.id, 'claude-code') == 'sess-abc_1'
	// Providers are independent resume namespaces.
	assert store.get_cli_resume_id(session.id, 'codex') == ''
	store.set_cli_resume_id(session.id, 'claude-code', 'sess-def_2') or { panic(err) }
	assert store.get_cli_resume_id(session.id, 'claude-code') == 'sess-def_2'
	store.clear_cli_resume_id(session.id, 'claude-code') or { panic(err) }
	assert store.get_cli_resume_id(session.id, 'claude-code') == ''
	// Unsafe ids are refused at the store boundary.
	store.set_cli_resume_id(session.id, 'claude-code', '--evil') or {
		assert err.msg().contains('unsafe')
		return
	}
	panic('unsafe CLI session id must be refused')
}

fn test_cli_resume_prompt_is_latest_user_message() {
	assert cli_resume_prompt([
		ChatMessage{
			role:    'user'
			content: 'first'
		},
		ChatMessage{
			role:    'assistant'
			content: 'answer'
		},
		ChatMessage{
			role:    'user'
			content: 'second'
		},
	]) == 'second'
	assert cli_resume_prompt([
		ChatMessage{
			role:    'assistant'
			content: 'only'
		},
	]) == ''
}

fn resume_node_available() bool {
	result := os.execute('node --version')
	return result.exit_code == 0
}

fn resume_shim_path() (string, bool) {
	if !resume_node_available() {
		eprintln('skip: node unavailable for resume fixture')
		return '', false
	}
	fixture := os.join_path('tests', 'focus_reference', 'testing', 'fake-claude.mjs')
	if !os.exists(fixture) {
		eprintln('skip: fake-claude fixture not present')
		return '', false
	}
	shim_dir := os.join_path(os.temp_dir(), 'veasel-cli-resume-test')
	os.mkdir_all(shim_dir) or { panic(err) }
	shim := os.join_path(shim_dir, 'claude')
	os.write_file(shim, '#!/bin/sh\nexec node "${os.abs_path(fixture)}" "$@"\n') or {
		panic(err)
	}
	os.chmod(shim, 0o755) or { panic(err) }
	old_path := os.getenv('PATH')
	os.setenv('PATH', shim_dir + ':' + old_path, true)
	return old_path, true
}

fn test_complete_cli_turn_resumes_and_falls_back() {
	old_path, ok := resume_shim_path()
	if !ok {
		return
	}
	defer { os.setenv('PATH', old_path, true) }
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{
		title: 'resume-e2e'
	}) or { panic(err) }
	config := ModelConfig{
		provider: 'claude-code'
		model:    'default'
	}
	first := complete_cli_provider_turn_with_resume(mut store, session.id, [
		ChatMessage{
			role:    'user'
			content: 'hello'
		},
	], config, os.getwd(), ignore_provider_text_delta, deny_all_cli_approvals) or {
		panic(err)
	}
	assert first.cli_session_id == 'sess-fake-1'
	assert store.get_cli_resume_id(session.id, 'claude-code') == 'sess-fake-1'

	second := complete_cli_provider_turn_with_resume(mut store, session.id, [
		ChatMessage{
			role:    'user'
			content: 'hello'
		},
		ChatMessage{
			role:    'assistant'
			content: 'hi there'
		},
		ChatMessage{
			role:    'user'
			content: 'again please'
		},
	], config, os.getwd(), ignore_provider_text_delta, deny_all_cli_approvals) or {
		panic(err)
	}
	// Resumed turns send only the latest user message, not the transcript.
	assert second.content.contains('again please')
	assert !second.content.contains('user: hello')
	assert second.cli_session_id == 'sess-fake-1'

	// A stale CLI session clears and retries once from the full canonical
	// transcript; the fresh id replaces the stale one.
	store.set_cli_resume_id(session.id, 'claude-code', 'gone') or { panic(err) }
	third := complete_cli_provider_turn_with_resume(mut store, session.id, [
		ChatMessage{
			role:    'user'
			content: 'hello'
		},
		ChatMessage{
			role:    'assistant'
			content: 'hi there'
		},
		ChatMessage{
			role:    'user'
			content: 'again please'
		},
	], config, os.getwd(), ignore_provider_text_delta, deny_all_cli_approvals) or {
		panic(err)
	}
	assert third.content.contains('user: hello')
	assert third.cli_session_id == 'sess-fake-1'
	assert store.get_cli_resume_id(session.id, 'claude-code') == 'sess-fake-1'
}

fn fixture_shim(name string, fixture_path string) (string, bool) {
	if !resume_node_available() {
		return '', false
	}
	fixture := os.join_path(fixture_path)
	if !os.exists(fixture) {
		return '', false
	}
	shim := os.join_path(os.temp_dir(), 'veasel-fake-${name}-resume-test.sh')
	os.write_file(shim, '#!/bin/sh\nexec node "${os.abs_path(fixture)}" "$@"\n') or {
		panic(err)
	}
	os.chmod(shim, 0o755) or { panic(err) }
	return shim, true
}

fn test_codex_turn_resumes_existing_thread() {
	shim, ok := fixture_shim('codex', os.join_path('tests', 'focus_reference', 'testing',
		'fake-codex.mjs'))
	if !ok {
		return
	}
	defer { os.rm(shim) or {} }
	turn := run_codex_cli_turn(shim, os.getwd(), 'ask', '', 'parent', 'scope', 30_000,
		ignore_provider_text_delta, deny_all_cli_approvals) or { panic(err) }
	assert turn.outcome == 'completed'
	assert turn.thread_id == 'parent'
}

fn test_acp_turn_loads_existing_session() {
	shim, ok := fixture_shim('opencode', os.join_path('tests', 'focus_reference', 'testing',
		'fake-opencode.mjs'))
	if !ok {
		return
	}
	defer { os.rm(shim) or {} }
	turn := run_acp_cli_turn(shim, ['acp'], os.getwd(), []AcpSessionConfig{}, 'ses_fake_focus_1',
		'hello', 30_000, ignore_provider_text_delta, deny_all_cli_approvals) or {
		panic(err)
	}
	assert turn.outcome == 'completed'
	assert turn.session_id == 'ses_fake_focus_1'
	assert turn.text == 'ACP_OK'
}
