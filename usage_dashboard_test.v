module main

fn test_global_usage_groups_provider_reported_metrics_by_model() {
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{
		title:     'Usage dashboard'
		directory: '/tmp/usage-dashboard'
	}) or { panic(err) }
	openai_turn := '03b42ec1-8f56-45f8-9146-9a0d93f1d501'
	other_turn := '13b42ec1-8f56-45f8-9146-9a0d93f1d502'
	_ = store.create_session_operation(session.id, openai_turn) or { panic(err) }
	_ = store.append_exchange(session.id, openai_turn, 'one', 'a', 'openai-compatible', 'fixture',
		'', ProviderUsage{
			input_tokens:          100
			output_tokens:         20
			cache_read_tokens:     12
			cache_creation_tokens: 4
			cache_reported:        true
			reasoning_tokens:      7
			reasoning_reported:    true
			reported:              true
		}) or { panic(err) }
	_ = store.create_session_operation(session.id, other_turn) or { panic(err) }
	_ = store.append_exchange(session.id, other_turn, 'two', 'b', 'anthropic', 'fixture-2', '',
		ProviderUsage{}) or { panic(err) }
	summary := store.usage_summary() or { panic(err) }
	assert summary.models.len == 2
	assert summary.models[0].provider == 'anthropic'
	assert summary.models[0].model == 'fixture-2'
	assert summary.models[0].completed_turns == 1
	assert summary.models[0].reported_turns == 0
	assert summary.models[0].input_tokens == 0
	assert !summary.models[0].cache_reported
	assert summary.models[0].cache_reported_turns == 0
	assert !summary.models[0].reasoning_reported
	assert summary.models[0].reasoning_reported_turns == 0
	assert summary.models[0].cost == 'unavailable'
	assert summary.models[1].provider == 'openai-compatible'
	assert summary.models[1].model == 'fixture'
	assert summary.models[1].reported_turns == 1
	assert summary.models[1].input_tokens == 100
	assert summary.models[1].output_tokens == 20
	assert summary.models[1].cache_reported
	assert summary.models[1].cache_reported_turns == 1
	assert summary.models[1].cache_read_tokens == 12
	assert summary.models[1].cache_creation_tokens == 4
	assert summary.models[1].reasoning_reported
	assert summary.models[1].reasoning_reported_turns == 1
	assert summary.models[1].reasoning_tokens == 7
	assert summary.models[1].cost == 'unavailable'
}
