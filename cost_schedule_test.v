module main

import os
import uuid

fn test_format_usd_amount_compacts_fraction() {
	assert format_usd_amount(0) == '$0.00'
	assert format_usd_amount(0.0123) == '$0.0123'
	assert format_usd_amount(1.5) == '$1.5'
	assert format_usd_amount(2) == '$2.00'
}

fn test_compute_turn_cost_anthropic_disjoint_cache() {
	schedule := cost_schedule_from_embedded()
	amount := compute_turn_cost_usd(schedule, CostScheduleTurn{
		provider:              'anthropic'
		model:                 'claude-sonnet-4-5'
		input_tokens:          1_000_000
		output_tokens:         500_000
		usage_reported:        true
		cache_read_tokens:     200_000
		cache_creation_tokens: 100_000
		cache_reported:        true
	}) or { panic(err) }
	// 1M*3 + 0.5M*15 + 0.2M*0.3 + 0.1M*3.75 = 3 + 7.5 + 0.06 + 0.375 = 10.935
	assert format_usd_amount(amount) == '$10.935'
}

fn test_compute_turn_cost_openai_subset_cache() {
	schedule := cost_schedule_from_embedded()
	amount := compute_turn_cost_usd(schedule, CostScheduleTurn{
		provider:              'openai'
		model:                 'gpt-4o'
		input_tokens:          1_000_000
		output_tokens:         0
		usage_reported:        true
		cache_read_tokens:     400_000
		cache_creation_tokens: 0
		cache_reported:        true
	}) or { panic(err) }
	// billable input 600k @ 2.5 + cache_read 400k @ 1.25 = 1.5 + 0.5 = 2.0
	assert format_usd_amount(amount) == '$2.00'
}

fn test_session_usage_cost_unavailable_when_model_missing() {
	label := session_usage_cost_label([
		CostScheduleTurn{
			provider:       'anthropic'
			model:          'claude-not-in-schedule'
			input_tokens:   1000
			output_tokens:  1000
			usage_reported: true
		},
	])
	assert label == cost_unavailable
}

fn test_provider_reported_cost_takes_precedence_without_a_model_rate() {
	schedule := CostSchedule{
		unit:    embedded_cost_schedule_unit
		entries: map[string]CostScheduleEntry{}
	}
	turn := CostScheduleTurn{
		provider_cost_usd: f64(0)
	}
	assert usage_cost_label(schedule, [turn]) == '$0.00'
}

fn test_provider_reported_billing_persists_and_appears_in_usage_summaries() {
	prior := os.getenv_opt(cost_schedule_env) or { '' }
	os.unsetenv(cost_schedule_env)
	defer {
		if prior.len == 0 {
			os.unsetenv(cost_schedule_env)
		} else {
			os.setenv(cost_schedule_env, prior, true)
		}
	}
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{
		title:     'Provider billing'
		directory: '/tmp/provider-billing'
	}) or { panic(err) }
	operation := 'a1b2c3d4-e5f6-4789-a012-3456789abcde'
	_ = store.create_session_operation(session.id, operation) or { panic(err) }
	_ = store.append_exchange(session.id, operation, 'hi', 'there', 'opencode-go',
		'fixture-model', '', ProviderUsage{
			reported_cost_usd: f64(0)
			allowance_usd:     f64(0.0042)
		}) or { panic(err) }
	session_summary := store.session_usage_summary(session.id) or { panic(err) }
	global_summary := store.usage_summary() or { panic(err) }
	assert session_summary.reported_turns == 0
	assert session_summary.cost == '$0.00'
	assert session_summary.allowance_reported
	assert session_summary.allowance_usd == f64(0.0042)
	assert global_summary.cost == '$0.00'
	assert global_summary.allowance_reported
	assert global_summary.allowance_usd == f64(0.0042)
}

fn test_reported_cost_precedes_schedule_and_unreported_costs_use_pinned_rates() {
	prior := os.getenv_opt(cost_schedule_env) or { '' }
	os.unsetenv(cost_schedule_env)
	defer {
		if prior.len == 0 {
			os.unsetenv(cost_schedule_env)
		} else {
			os.setenv(cost_schedule_env, prior, true)
		}
	}
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{
		title:     'Reported and scheduled cost'
		directory: '/tmp/reported-and-scheduled-cost'
	}) or { panic(err) }
	first := 'a1b2c3d4-e5f6-4789-a012-3456789abcde'
	second := 'a1b2c3d4-e5f6-4789-a012-3456789abcdf'
	_ = store.create_session_operation(session.id, first) or { panic(err) }
	_ = store.append_exchange(session.id, first, 'hi', 'there', 'anthropic',
		'claude-sonnet-4-5', '', ProviderUsage{
			input_tokens:      1_000_000
			reported:          true
			reported_cost_usd: f64(0.000123)
		}) or { panic(err) }
	_ = store.create_session_operation(session.id, second) or { panic(err) }
	_ = store.append_exchange(session.id, second, 'hi', 'there', 'anthropic',
		'claude-sonnet-4-5', '', ProviderUsage{
			input_tokens: 1_000_000
			reported:     true
		}) or { panic(err) }
	session_summary := store.session_usage_summary(session.id) or { panic(err) }
	global_summary := store.usage_summary() or { panic(err) }
	assert session_summary.cost == '$3.000123'
	assert global_summary.cost == '$3.000123'
}

fn test_load_cost_schedule_override_and_session_summary() {
	path := os.join_path(os.temp_dir(), 'veasel-cost-schedule-${uuid.new_v4().str()}.json')
	defer {
		os.rm(path) or {}
		os.unsetenv(cost_schedule_env)
	}
	os.write_file(path, '{
  "schema_version": 1,
  "unit": "usd_per_million_tokens",
  "models": [
    {"provider":"openai","model":"fixture-model","input":1.0,"output":2.0}
  ]
}
') or { panic(err) }
	os.setenv(cost_schedule_env, path, true)
	schedule := active_cost_schedule()
	assert schedule.entries.len == 1
	amount := compute_turn_cost_usd(schedule, CostScheduleTurn{
		provider:       'openai'
		model:          'fixture-model'
		input_tokens:   1_000_000
		output_tokens:  1_000_000
		usage_reported: true
	}) or { panic(err) }
	assert format_usd_amount(amount) == '$3.00'
}

fn test_embedded_schedule_matches_checked_in_json() {
	raw := os.read_file('tools/cost-schedule/schedule.json') or { panic(err) }
	from_file := load_cost_schedule_from_json(raw) or { panic(err) }
	embedded := cost_schedule_from_embedded()
	assert from_file.entries.len == embedded.entries.len
	assert from_file.entries.len >= 50
	sonnet := lookup_cost_schedule_entry(embedded, 'anthropic', 'claude-sonnet-4-5') or {
		panic('missing sonnet')
	}
	assert sonnet.input == 3.0
	assert sonnet.output == 15.0
	spark := lookup_cost_schedule_entry(embedded, 'meta', 'muse-spark-1.3') or {
		panic('missing muse-spark')
	}
	assert spark.input == 1.25
	assert spark.output == 4.25
	// Muse Wonder has no Models.dev [cost] at the pin — stay unpriced.
	if _ := lookup_cost_schedule_entry(embedded, 'meta', 'muse-wonder-1.0') {
		panic('muse-wonder must stay unpriced without invented rates')
	}
}

fn test_annotate_model_catalog_with_cost_schedule_rates() {
	prior := os.getenv_opt(cost_schedule_env) or { '' }
	os.unsetenv(cost_schedule_env)
	defer {
		if prior.len == 0 {
			os.unsetenv(cost_schedule_env)
		} else {
			os.setenv(cost_schedule_env, prior, true)
		}
	}
	models := [
		ModelCatalogEntry{
			id:   'claude-sonnet-4-5'
			name: 'Claude Sonnet 4.5'
		},
		ModelCatalogEntry{
			id:   'totally-unknown-model'
			name: 'Unknown'
		},
	]
	annotated := annotate_model_catalog_with_cost_schedule('anthropic', models)
	assert annotated.len == 2
	assert annotated[0].id == 'claude-sonnet-4-5'
	assert (annotated[0].input_per_mtok or { -1.0 }) == 3.0
	assert (annotated[0].output_per_mtok or { -1.0 }) == 15.0
	assert annotated[0].cost_unit == embedded_cost_schedule_unit
	assert annotated[1].id == 'totally-unknown-model'
	assert annotated[1].input_per_mtok == none
	assert annotated[1].output_per_mtok == none
	assert annotated[1].cost_unit == ''
}

fn test_session_usage_summary_prices_matching_schedule_models() {
	prior := os.getenv_opt(cost_schedule_env) or { '' }
	os.unsetenv(cost_schedule_env)
	defer {
		if prior.len == 0 {
			os.unsetenv(cost_schedule_env)
		} else {
			os.setenv(cost_schedule_env, prior, true)
		}
	}
	mut store := open_store(':memory:') or { panic(err) }
	defer {
		store.close() or {}
	}
	session := store.create_session(SessionInput{
		title:     'Priced usage'
		directory: '/tmp/priced-usage'
	}) or { panic(err) }
	op := 'a1b2c3d4-e5f6-4789-a012-3456789abcde'
	_ = store.create_session_operation(session.id, op) or { panic(err) }
	_ = store.append_exchange(session.id, op, 'hi', 'there', 'anthropic', 'claude-sonnet-4-5',
		'', ProviderUsage{
			input_tokens:   1_000_000
			output_tokens:  0
			reported:       true
			cache_reported: false
		}) or { panic(err) }
	summary := store.session_usage_summary(session.id) or { panic(err) }
	assert summary.cost == '$3.00'
}

fn test_global_usage_summary_prices_grouped_turns() {
	prior := os.getenv_opt(cost_schedule_env) or { '' }
	os.unsetenv(cost_schedule_env)
	defer {
		if prior.len == 0 {
			os.unsetenv(cost_schedule_env)
		} else {
			os.setenv(cost_schedule_env, prior, true)
		}
	}
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{
		title:     'Grouped global usage'
		directory: '/tmp/grouped-global-usage'
	}) or { panic(err) }
	for index in 1 .. 3 {
		operation := 'a1b2c3d4-e5f6-4789-a012-3456789ab${index:03}'
		_ = store.create_session_operation(session.id, operation) or { panic(err) }
		_ = store.append_exchange(session.id, operation, 'hi', 'there', 'anthropic',
			'claude-sonnet-4-5', '', ProviderUsage{
				input_tokens: 1_000_000
				reported:     true
			}) or { panic(err) }
	}
	summary := store.usage_summary() or { panic(err) }
	assert summary.reported_turns == 2
	assert summary.cost == '$6.00'
}

fn test_global_usage_cost_preserves_invalid_cached_input_guard_after_grouping() {
	prior := os.getenv_opt(cost_schedule_env) or { '' }
	os.unsetenv(cost_schedule_env)
	defer {
		if prior.len == 0 {
			os.unsetenv(cost_schedule_env)
		} else {
			os.setenv(cost_schedule_env, prior, true)
		}
	}
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{
		title:     'Invalid cached usage'
		directory: '/tmp/invalid-cached-usage'
	}) or { panic(err) }
	for index in 0 .. 2 {
		input_tokens := if index == 0 { i64(1) } else { i64(10) }
		cache_tokens := if index == 0 { i64(2) } else { i64(0) }
		operation := 'b1b2c3d4-e5f6-4789-a012-3456789ab${index:03}'
		_ = store.create_session_operation(session.id, operation) or { panic(err) }
		_ = store.append_exchange(session.id, operation, 'hi', 'there', 'openai', 'gpt-4o', '',
			ProviderUsage{
				input_tokens:      input_tokens
				reported:          true
				cache_read_tokens: cache_tokens
				cache_reported:    true
			}) or { panic(err) }
	}
	summary := store.usage_summary() or { panic(err) }
	assert summary.cost == cost_unavailable
}
