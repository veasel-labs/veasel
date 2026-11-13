module main

import os
import json2
import uuid

fn agent_budget_reservation_error(mut store Store, session_id string, tokens i64,
	policy AgentTokenBudgetPolicy) string {
	_ := store.reserve_agent_provider_call(session_id, tokens, policy) or { return err.msg() }
	return ''
}

fn reserve_agent_budget_concurrently(store &Store, session_id string, tokens i64,
	policy AgentTokenBudgetPolicy, results chan string) {
	mut mutable_store := store
	if _ := mutable_store.reserve_agent_provider_call(session_id, tokens, policy) {
		results <- 'reserved'
	} else {
		results <- err.msg()
	}
}

fn test_agent_token_budget_policy_defaults_and_validation() {
	prior_child := os.getenv_opt('VEASEL_AGENT_CHILD_TOKEN_BUDGET')
	prior_parent := os.getenv_opt('VEASEL_AGENT_PARENT_TOKEN_BUDGET')
	defer {
		if value := prior_child {
			os.setenv('VEASEL_AGENT_CHILD_TOKEN_BUDGET', value, true)
		} else {
			os.unsetenv('VEASEL_AGENT_CHILD_TOKEN_BUDGET')
		}
		if value := prior_parent {
			os.setenv('VEASEL_AGENT_PARENT_TOKEN_BUDGET', value, true)
		} else {
			os.unsetenv('VEASEL_AGENT_PARENT_TOKEN_BUDGET')
		}
	}
	os.unsetenv('VEASEL_AGENT_CHILD_TOKEN_BUDGET')
	os.unsetenv('VEASEL_AGENT_PARENT_TOKEN_BUDGET')
	defaults := agent_token_budget_policy() or { panic(err) }
	assert defaults.child_tokens == default_child_agent_token_budget
	assert defaults.parent_tokens == default_parent_agent_token_budget

	os.setenv('VEASEL_AGENT_CHILD_TOKEN_BUDGET', '12', true)
	os.setenv('VEASEL_AGENT_PARENT_TOKEN_BUDGET', '20', true)
	configured := agent_token_budget_policy() or { panic(err) }
	assert configured.child_tokens == 12
	assert configured.parent_tokens == 20
	os.setenv('VEASEL_AGENT_CHILD_TOKEN_BUDGET', '21', true)
	agent_token_budget_policy() or {
		assert err.msg().contains('cannot exceed')
		return
	}
	assert false
}

fn test_provider_request_reservation_includes_tool_schema_output_and_retry_ceiling() {
	messages := [ChatMessage{ role: 'user', content: 'review this code' }]
	tools := [AgentToolDefinition{
		name:        'workspace_read_file'
		description: 'Read one file from the current workspace.'
	}]
	config := ModelConfig{
		max_output_tokens: 64
	}
	request_bytes := json2.encode[[]ChatMessage](messages).len + json2.encode[[]AgentToolDefinition](tools).len
	assert provider_call_reservation_tokens(messages, tools, config) ==
		i64(request_bytes + agent_token_budget_protocol_overhead_bytes + 64) * 3
	assert provider_call_reservation_tokens(messages, [], ModelConfig{}) ==
		i64(json2.encode[[]ChatMessage](messages).len + 2 +
			agent_token_budget_protocol_overhead_bytes + max_model_output_tokens) * 3
}

fn test_actual_token_usage_counts_anthropic_cache_separately_without_double_counting_others() {
	anthropic := ProviderUsage{
		input_tokens:          4
		output_tokens:         3
		cache_read_tokens:     2
		cache_creation_tokens: 1
		cache_reported:        true
	}
	assert actual_agent_provider_tokens('anthropic', anthropic) == 10
	openai := ProviderUsage{
		input_tokens:      4
		output_tokens:     3
		cache_read_tokens: 2
		cache_reported:    true
	}
	assert actual_agent_provider_tokens('openai', openai) == 7
}

fn test_agent_token_budget_reservations_enforce_child_and_parent_and_report_provenance() {
	root := os.join_path(os.temp_dir(), 'veasel-agent-budget-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	workspace := os.join_path(root, 'workspace')
	os.mkdir_all(workspace) or { panic(err) }
	_ := run_workspace_git_command(workspace, ['init', '-b', 'main']) or { panic(err) }
	_ := run_workspace_git_command(workspace, ['config', 'user.email', 'veasel@example.com']) or {
		panic(err)
	}
	_ := run_workspace_git_command(workspace, ['config', 'user.name', 'Veasel']) or { panic(err) }
	os.write_file(os.join_path(workspace, 'README.md'), 'agent budget fixture\n') or { panic(err) }
	_ := run_workspace_git_command(workspace, ['add', 'README.md']) or { panic(err) }
	_ := run_workspace_git_command(workspace, ['commit', '-m', 'budget fixture']) or { panic(err) }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	parent := store.create_session(SessionInput{
		title:     'Budget parent'
		directory: workspace
	}) or { panic(err) }
	parent_op := store.ensure_subagent_parent_operation(parent.id) or { panic(err) }
	child_a := store.create_subagent_run_with_task(parent.id, parent_op, 'budget-child-a', 'explorer',
		1, 'Explorer A', workspace, 'Inspect the first file') or { panic(err) }
	child_b := store.create_subagent_run_with_task(parent.id, parent_op, 'budget-child-b', 'explorer',
		1, 'Explorer B', workspace, 'Inspect the second file') or { panic(err) }
	policy := AgentTokenBudgetPolicy{
		child_tokens:  10
		parent_tokens: 15
	}
	reservation := store.reserve_agent_provider_call(child_a.child_session_id, 8, policy) or {
		panic(err)
	}
	assert agent_budget_reservation_error(mut store, child_a.child_session_id, 3,
		policy).contains('child agent token budget exhausted')
	second := store.reserve_agent_provider_call(child_b.child_session_id, 7, policy) or { panic(err) }
	assert agent_budget_reservation_error(mut store, parent.id, 1,
		policy).contains('parent agent token budget exhausted')
	store.settle_agent_provider_call(reservation, 'openai', ProviderUsage{
		input_tokens:      5
		output_tokens:     3
		total_tokens:      8
		reported:          true
		reported_cost_usd: f64(0.00125)
	}, 1) or { panic(err) }
	store.settle_agent_provider_call(second, 'openai', ProviderUsage{
		input_tokens:      4
		output_tokens:     3
		total_tokens:      7
		reported:          true
		reported_cost_usd: f64(0.00075)
	}, 1) or { panic(err) }
	_ = store.create_session_operation(child_a.child_session_id, child_a.child_operation_id) or {
		panic(err)
	}
	_ = store.db.exec_param_many("UPDATE session_operations SET status = 'completed', provider_cost_usd = ?, provider_cost_reported = 1 WHERE id = ? AND session_id = ?", [
		'0.00125',
		child_a.child_operation_id,
		child_a.child_session_id,
	]) or { panic(err) }
	child_detail := store.get_subagent_run(child_a.id) or { panic(err) }
	assert child_detail.cost_reported
	assert (child_detail.reported_cost_usd or { -1.0 }) == f64(0.00125)
	summary := store.agent_token_budget_summary(child_a.child_session_id, policy) or { panic(err) }
	assert summary.root_session_id == parent.id
	assert summary.per_child_token_limit == 10
	assert summary.parent_token_limit == 15
	assert summary.reserved_tokens == 0
	assert summary.accounted_tokens == 15
	assert summary.actual_tokens == 15
	assert summary.provider_calls == 2
	assert summary.usage_reported_calls == 2
	assert summary.usage_complete
	assert summary.cost_reported_calls == 2
	assert summary.cost_reported
	assert (summary.reported_cost_usd or { -1.0 }) == f64(0.002)
}

fn test_agent_token_budget_uncertain_reservation_is_not_reported_as_actual_or_cost() {
	root := os.join_path(os.temp_dir(), 'veasel-agent-budget-uncertain-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{
		title:     'Budget uncertainty'
		directory: root
	}) or { panic(err) }
	policy := AgentTokenBudgetPolicy{
		child_tokens:  10
		parent_tokens: 20
	}
	reservation := store.reserve_agent_provider_call(session.id, 9, policy) or { panic(err) }
	store.abandon_agent_provider_call(reservation)
	summary := store.agent_token_budget_summary(session.id, policy) or { panic(err) }
	assert summary.reserved_tokens == 0
	assert summary.accounted_tokens == 9
	assert summary.actual_tokens == 0
	assert summary.provider_calls == 1
	assert !summary.usage_complete
	assert !summary.cost_reported
	assert summary.reported_cost_usd == none
}

fn test_agent_token_budget_retry_retains_full_reservation_and_withholds_partial_cost() {
	root := os.join_path(os.temp_dir(), 'veasel-agent-budget-retry-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{
		title:     'Budget retry'
		directory: root
	}) or { panic(err) }
	policy := AgentTokenBudgetPolicy{
		child_tokens:  10
		parent_tokens: 20
	}
	reservation := store.reserve_agent_provider_call(session.id, 9, policy) or { panic(err) }
	store.settle_agent_provider_call(reservation, 'openai', ProviderUsage{
		input_tokens:      4
		output_tokens:     3
		total_tokens:      7
		reported:          true
		reported_cost_usd: f64(0.002)
	}, 2) or { panic(err) }
	summary := store.agent_token_budget_summary(session.id, policy) or { panic(err) }
	assert summary.accounted_tokens == 9
	assert summary.actual_tokens == 0
	assert !summary.usage_complete
	assert !summary.cost_reported
	assert summary.reported_cost_usd == none
}

fn test_agent_token_budget_reservations_are_atomic_across_concurrent_children() {
	root := os.join_path(os.temp_dir(), 'veasel-agent-budget-parallel-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	parent := store.create_session(SessionInput{
		title:     'Parallel budget parent'
		directory: root
	}) or { panic(err) }
	policy := AgentTokenBudgetPolicy{
		child_tokens:  10
		parent_tokens: 10
	}
	results := chan string{cap: 2}
	spawn reserve_agent_budget_concurrently(store, parent.id, 6, policy, results)
	spawn reserve_agent_budget_concurrently(store, parent.id, 6, policy, results)
	first := <-results
	second := <-results
	assert (first == 'reserved' && second.contains('parent agent token budget exhausted'))
		|| (second == 'reserved' && first.contains('parent agent token budget exhausted'))
	summary := store.agent_token_budget_summary(parent.id, policy) or { panic(err) }
	assert summary.accounted_tokens == 6
	assert summary.reserved_tokens == 6
	assert summary.provider_calls == 1
}

fn test_agent_token_budget_reservation_becomes_uncertain_after_store_recovery() {
	root := os.join_path(os.temp_dir(), 'veasel-agent-budget-recovery-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	db_path := os.join_path(root, 'veasel.sqlite3')
	mut store := open_store(db_path) or { panic(err) }
	session := store.create_session(SessionInput{
		title:     'Budget recovery'
		directory: root
	}) or { panic(err) }
	policy := AgentTokenBudgetPolicy{
		child_tokens:  10
		parent_tokens: 20
	}
	_ := store.reserve_agent_provider_call(session.id, 9, policy) or { panic(err) }
	store.close() or { panic(err) }
	mut reopened := open_store(db_path) or { panic(err) }
	defer { reopened.close() or {} }
	summary := reopened.agent_token_budget_summary(session.id, policy) or { panic(err) }
	assert summary.reserved_tokens == 0
	assert summary.accounted_tokens == 9
	assert summary.actual_tokens == 0
	assert !summary.usage_complete
	assert !summary.cost_reported
}
