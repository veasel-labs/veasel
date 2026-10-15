module main

fn test_openai_chat_usage_parses_cached_tokens_subset() {
	usage := provider_usage_from_fixture_json('openai-chat', '{
		"prompt_tokens": 1200,
		"completion_tokens": 40,
		"total_tokens": 1240,
		"prompt_tokens_details": {"cached_tokens": 900}
	}') or { panic(err) }
	assert usage.reported
	assert usage.input_tokens == 1200
	assert usage.output_tokens == 40
	assert usage.total_tokens == 1240
	assert usage.cache_reported
	assert usage.cache_read_tokens == 900
	assert usage.cache_creation_tokens == 0
}

fn test_openai_chat_usage_omits_cache_when_details_absent() {
	usage := provider_usage_from_fixture_json('openai-chat', '{
		"prompt_tokens": 100,
		"completion_tokens": 10,
		"total_tokens": 110
	}') or { panic(err) }
	assert usage.reported
	assert usage.input_tokens == 100
	assert !usage.cache_reported
	assert usage.cache_read_tokens == 0
	assert usage.cache_creation_tokens == 0
}

fn test_openai_responses_usage_parses_cache_read_and_write() {
	usage := provider_usage_from_fixture_json('openai-responses', '{
		"input_tokens": 2000,
		"output_tokens": 50,
		"total_tokens": 2050,
		"input_tokens_details": {"cached_tokens": 1500, "cache_write_tokens": 100}
	}') or { panic(err) }
	assert usage.reported
	assert usage.cache_reported
	assert usage.cache_read_tokens == 1500
	assert usage.cache_creation_tokens == 100
}

fn test_anthropic_usage_parses_disjoint_cache_fields() {
	usage := provider_usage_from_fixture_json('anthropic', '{
		"input_tokens": 50,
		"output_tokens": 12,
		"cache_read_input_tokens": 100000,
		"cache_creation_input_tokens": 0
	}') or { panic(err) }
	assert usage.reported
	assert usage.input_tokens == 50
	assert usage.output_tokens == 12
	assert usage.cache_reported
	assert usage.cache_read_tokens == 100000
	assert usage.cache_creation_tokens == 0
}

fn test_anthropic_usage_omits_cache_when_fields_absent() {
	usage := provider_usage_from_fixture_json('anthropic', '{
		"input_tokens": 80,
		"output_tokens": 20
	}') or { panic(err) }
	assert usage.reported
	assert !usage.cache_reported
	assert usage.cache_read_tokens == 0
	assert usage.cache_creation_tokens == 0
}

fn test_anthropic_usage_reports_explicit_zero_cache_fields() {
	usage := provider_usage_from_fixture_json('anthropic', '{
		"input_tokens": 80,
		"output_tokens": 20,
		"cache_read_input_tokens": 0,
		"cache_creation_input_tokens": 0
	}') or { panic(err) }
	assert usage.reported
	assert usage.cache_reported
	assert usage.cache_read_tokens == 0
	assert usage.cache_creation_tokens == 0
}

fn test_gemini_usage_parses_cached_content_subset() {
	usage := provider_usage_from_fixture_json('gemini', '{
		"promptTokenCount": 500,
		"candidatesTokenCount": 25,
		"totalTokenCount": 525,
		"cachedContentTokenCount": 400
	}') or { panic(err) }
	assert usage.reported
	assert usage.input_tokens == 500
	assert usage.cache_reported
	assert usage.cache_read_tokens == 400
	assert usage.cache_creation_tokens == 0
}

fn test_gemini_usage_omits_cache_when_field_absent() {
	usage := provider_usage_from_fixture_json('gemini', '{
		"promptTokenCount": 50,
		"candidatesTokenCount": 5,
		"totalTokenCount": 55
	}') or { panic(err) }
	assert usage.reported
	assert !usage.cache_reported
	assert usage.cache_read_tokens == 0
}

fn test_add_provider_usage_sums_cache_only_when_reported() {
	first := ProviderUsage{
		input_tokens:      10
		output_tokens:     2
		total_tokens:      12
		cache_read_tokens: 100
		cache_reported:    true
		reported:          true
	}
	second := ProviderUsage{
		input_tokens:  5
		output_tokens: 1
		total_tokens:  6
		reported:      true
	}
	sum := add_provider_usage(first, second)
	assert sum.input_tokens == 15
	assert sum.output_tokens == 3
	assert sum.cache_reported
	assert sum.cache_read_tokens == 100
}
