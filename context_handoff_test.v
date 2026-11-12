module main

import os
import json2
import uuid

fn test_context_handoff_preserves_session_route_identity_delta_and_permission_provenance() {
	root := os.join_path(os.temp_dir(), 'veasel-context-handoff-chain-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	workspace := init_context_handoff_repo(root)
	database := os.join_path(root, 'veasel.sqlite3')
	mut store := open_store(database) or { panic(err) }
	parent := store.create_session(SessionInput{ title: 'Provider switching', directory: workspace }) or {
		panic(err)
	}
	operation_a := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, operation_a) or { panic(err) }
	_ = store.append_exchange(parent.id, operation_a, 'Question on A', 'Answer from A', 'anthropic',
		'claude-test', '', ProviderUsage{}) or { panic(err) }
	operation_b := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, operation_b) or { panic(err) }
	policy := ExecutionPolicyTurn{ mode: .ask, interactive: true }
	to_b := store.persist_context_handoff(parent.id, operation_b, 'google', 'gemini-test', policy,
		'parent_turn') or { panic(err) }
	assert to_b.session_id == parent.id
	assert to_b.source_operation_id == operation_a
	assert to_b.next_operation_id == operation_b
	assert to_b.source_provider == 'anthropic'
	assert to_b.source_model == 'claude-test'
	assert to_b.target_provider == 'google'
	assert to_b.target_model == 'gemini-test'
	assert to_b.context_mode == 'full'
	assert to_b.transcript.len == 2
	assert to_b.transcript_complete
	assert to_b.permission_policy_source == 'parent_turn'
	assert to_b.permission_policy_mode == 'ask'
	assert to_b.permission_interactive
	assert to_b.permissions_inherited
	assert !to_b.hidden_reasoning_transferred
	assert to_b.workspace_snapshot_ref.starts_with('git-head:')
	assert to_b.workspace_snapshot_scope.contains('committed-head-only')

	_ = store.append_exchange(parent.id, operation_b, 'Question on B', 'Answer from B', 'google',
		'gemini-test', '', ProviderUsage{}) or { panic(err) }
	operation_c := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, operation_c) or { panic(err) }
	to_c := store.persist_context_handoff(parent.id, operation_c, 'openai', 'gpt-test', policy,
		'parent_turn') or { panic(err) }
	assert to_c.session_id == parent.id
	assert to_c.source_operation_id == operation_b
	assert to_c.next_operation_id == operation_c
	assert to_c.source_provider == 'google'
	assert to_c.source_model == 'gemini-test'
	assert to_c.target_provider == 'openai'
	assert to_c.target_model == 'gpt-test'
	assert to_c.context_mode == 'delta'
	assert to_c.base_message_id == to_b.through_message_id
	assert to_c.transcript.len == 2
	assert to_c.transcript[0].content == 'Question on B'
	assert to_c.transcript[1].content == 'Answer from B'
	assert to_c.permission_policy_mode == to_b.permission_policy_mode
	assert to_c.permission_interactive == to_b.permission_interactive
	assert !to_c.hidden_reasoning_transferred
	assert store.list_context_handoffs(parent.id) or { panic(err) }.len == 2
	retry := store.persist_context_handoff(parent.id, operation_c, 'openai', 'gpt-test', policy,
		'parent_turn') or { panic(err) }
	assert retry.artifact_id == to_c.artifact_id
	assert store.list_context_handoffs(parent.id) or { panic(err) }.len == 2
	store.close() or { panic(err) }

	mut recovered := open_store(database) or { panic(err) }
	defer { recovered.close() or {} }
	restored := recovered.context_handoff_for_operation(parent.id, operation_c) or {
		panic('context handoff did not survive store reopen')
	}
	assert restored.session_id == parent.id
	assert restored.artifact_id == to_c.artifact_id
	assert restored.source_provider == 'google'
	assert restored.target_provider == 'openai'
}

fn test_context_handoff_falls_back_to_bounded_full_snapshot_when_delta_exceeds_limits() {
	root := os.join_path(os.temp_dir(), 'veasel-context-handoff-bounds-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	workspace := init_context_handoff_repo(root)
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	parent := store.create_session(SessionInput{ title: 'Bounded handoff', directory: workspace }) or {
		panic(err)
	}
	operation_a := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, operation_a) or { panic(err) }
	_ = store.append_exchange(parent.id, operation_a, 'A question', 'A answer', 'anthropic',
		'claude-test', '', ProviderUsage{}) or { panic(err) }
	operation_b := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, operation_b) or { panic(err) }
	policy := ExecutionPolicyTurn{ mode: .auto_edit, interactive: false }
	_ = store.persist_context_handoff(parent.id, operation_b, 'google', 'gemini-test', policy,
		'parent_turn') or { panic(err) }
	large := 'x'.repeat(max_context_handoff_transcript_bytes)
	_ = store.append_exchange(parent.id, operation_b, large, large, 'google', 'gemini-test', '',
		ProviderUsage{}) or { panic(err) }
	operation_c := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, operation_c) or { panic(err) }
	fallback := store.persist_context_handoff(parent.id, operation_c, 'openai', 'gpt-test', policy,
		'parent_turn') or { panic(err) }
	assert fallback.context_mode == 'full'
	assert fallback.fallback_reason.contains('delta exceeded')
	assert fallback.transcript_bytes <= max_context_handoff_transcript_bytes
	assert fallback.omitted_message_count > 0
	assert !fallback.transcript_complete
	assert fallback.permission_policy_mode == 'auto-edit'
	assert !fallback.permission_interactive
	assert fallback.permissions_inherited
	assert !fallback.hidden_reasoning_transferred
	assert json2.encode(fallback).len <= max_context_handoff_event_bytes
	_ = store.append_exchange(parent.id, operation_c, 'C question', 'C answer', 'openai',
		'gpt-test', '', ProviderUsage{}) or { panic(err) }
	operation_d := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, operation_d) or { panic(err) }
	after_incomplete := store.persist_context_handoff(parent.id, operation_d, 'anthropic',
		'claude-next', policy, 'parent_turn') or { panic(err) }
	assert after_incomplete.context_mode == 'full'
	assert after_incomplete.fallback_reason == 'previous handoff checkpoint was incomplete; using a bounded full-context snapshot'
	assert after_incomplete.transcript.any(it.content == 'C question')
	assert after_incomplete.transcript.any(it.content == 'C answer')
}

fn init_context_handoff_repo(root string) string {
	repo := os.join_path(root, 'workspace')
	os.mkdir_all(repo) or { panic(err) }
	_ := run_workspace_git_command(repo, ['init', '-b', 'main']) or { panic(err) }
	_ := run_workspace_git_command(repo, ['config', 'user.email', 'veasel@example.com']) or {
		panic(err)
	}
	_ := run_workspace_git_command(repo, ['config', 'user.name', 'Veasel']) or { panic(err) }
	os.write_file(os.join_path(repo, 'README.md'), 'base\n') or { panic(err) }
	_ := run_workspace_git_command(repo, ['add', 'README.md']) or { panic(err) }
	_ := run_workspace_git_command(repo, ['commit', '-m', 'base']) or { panic(err) }
	return repo
}
