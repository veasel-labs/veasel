module main

import os

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

fn test_explicit_model_context_window_overrides_curated_context() {
	prior := os.getenv('VEASEL_MODEL_CONTEXT_TOKENS')
	os.setenv('VEASEL_MODEL_CONTEXT_TOKENS', '4096', true)
	defer {
		if prior == '' {
			os.unsetenv('VEASEL_MODEL_CONTEXT_TOKENS')
		} else {
			os.setenv('VEASEL_MODEL_CONTEXT_TOKENS', prior, true)
		}
	}
	assert active_model_context_window(ModelConfig{
		provider: 'openai'
		model:    'gpt-4o'
	}) == 4096
}

fn test_invalid_model_context_window_keeps_curated_and_unknown_models_unknown() {
	prior := os.getenv('VEASEL_MODEL_CONTEXT_TOKENS')
	os.setenv('VEASEL_MODEL_CONTEXT_TOKENS', 'not-a-number', true)
	defer {
		if prior == '' {
			os.unsetenv('VEASEL_MODEL_CONTEXT_TOKENS')
		} else {
			os.setenv('VEASEL_MODEL_CONTEXT_TOKENS', prior, true)
		}
	}
	assert active_model_context_window(ModelConfig{
		provider: 'openai'
		model:    'gpt-4o'
	}) == 128_000
	assert active_model_context_window(ModelConfig{
		provider: 'ollama'
		model:    'custom-model'
	}) == 0
}

fn test_model_context_window_override_validation() {
	for valid in ['128', '4096', '1048576', ' 8192 '] {
		assert parse_model_context_window(valid) or { 0 } > 0
	}
	for invalid in ['', '0', '127', '1048577', '-4096', '4k', '4096.0', '9999999'] {
		assert parse_model_context_window(invalid) == none
	}
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
