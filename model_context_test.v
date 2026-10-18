module main

fn test_model_context_tokens_known_rows() {
	assert model_context_tokens('anthropic', 'claude-sonnet-4-6') or { 0 } == 1_000_000
	assert model_context_tokens('anthropic', 'claude-haiku-4-5') or { 0 } == 200_000
	assert model_context_tokens('gemini', 'gemini-2.5-pro') or { 0 } == 1_048_576
	assert model_context_tokens('meta', 'muse-spark-1.3') or { 0 } == 1_048_576
	assert model_context_tokens('openai', 'gpt-4o') or { 0 } == 128_000
	assert model_context_tokens('openai-responses', 'gpt-5.1') or { 0 } == 400_000
	assert model_context_tokens('meta', 'muse-wonder-1.0') or { 0 } == 1_048_576
	assert model_context_tokens('anthropic', 'claude-sonnet-4-5') or { 0 } == 200_000
	assert model_context_tokens('openai', 'gpt-5.1') or { 0 } == 400_000
}

fn test_model_context_tokens_unknown_rows_stay_unknown() {
	assert model_context_tokens('anthropic', 'claude-not-a-model') == none
	assert model_context_tokens('meta', 'muse-not-a-model') == none
	assert model_context_tokens('openai-compatible', 'gpt-4o') == none
	assert model_context_tokens('', 'gpt-4o') == none
	assert model_context_tokens('openai', '') == none
}

fn test_model_context_tokens_normalizes_provider_case() {
	assert model_context_tokens(' Anthropic ', 'claude-sonnet-4-6') or { 0 } == 1_000_000
}

fn test_annotate_model_catalog_with_context_schedule() {
	models := [
		ModelCatalogEntry{
			id:   'claude-sonnet-4-6'
			name: 'Claude Sonnet 4.6'
		},
		ModelCatalogEntry{
			id:   'muse-wonder-1.0'
			name: 'Muse Wonder'
		},
	]
	annotated := annotate_model_catalog_with_context_schedule('anthropic', [
		models[0],
	])
	assert annotated.len == 1
	assert (annotated[0].context_tokens or { 0 }) == 1_000_000
	meta := annotate_model_catalog_with_context_schedule('meta', [models[1]])
	assert (meta[0].context_tokens or { 0 }) == 1_048_576
}
