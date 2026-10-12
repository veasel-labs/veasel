module main

import os
import uuid
import json2

fn test_model_settings_persist_and_never_expose_credentials() {
	root := os.join_path(os.temp_dir(), 'veasel-model-settings-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'model-settings.json')
	mut state := new_model_settings_state(path)
	state.update(ModelSettingsInput{
		provider: 'anthropic'
		model:    'claude-sonnet-4-5'
		base_url: 'https://api.anthropic.com/v1'
		api_key:  'secret-token-value'
	}) or { panic(err) }
	view := state.view()
	assert view.active_provider == 'anthropic'
	assert view.profiles['anthropic'].model == 'claude-sonnet-4-5'
	assert view.profiles['anthropic'].api_key_saved
	assert !json2.encode(view).contains('secret-token-value')

	mut reloaded := new_model_settings_state(path)
	assert reloaded.view().active_provider == 'anthropic'
	assert reloaded.view().profiles['anthropic'].api_key_saved
	assert reloaded.view().profiles['anthropic'].base_url == 'https://api.anthropic.com/v1'
}

fn test_model_settings_preserve_key_when_blank_and_support_explicit_clear() {
	mut state := new_model_settings_state('')
	state.update(ModelSettingsInput{ provider: 'openai', model: 'gpt-5', base_url: 'https://api.openai.com/v1', api_key: 'saved' }) or {
		panic(err)
	}
	state.update(ModelSettingsInput{ provider: 'openai', model: 'gpt-5-mini', base_url: 'https://api.openai.com/v1' }) or {
		panic(err)
	}
	assert state.settings.profiles['openai'].api_key == 'saved'
	state.update(ModelSettingsInput{ provider: 'openai', model: 'gpt-5-mini', base_url: 'https://api.openai.com/v1', clear_api_key: true }) or {
		panic(err)
	}
	assert state.settings.profiles['openai'].api_key == ''
}

fn test_model_settings_reject_unsupported_provider_and_insecure_endpoint() {
	mut state := new_model_settings_state('')
	state.update(ModelSettingsInput{ provider: 'unknown', model: 'x', base_url: 'https://example.com' }) or {
		assert err.msg() == 'unsupported model provider'
		return
	}
	assert false
}

fn test_provider_catalog_includes_native_and_openai_compatible_options() {
	catalog := model_provider_catalog()
	assert catalog.len == supported_model_providers.len
	mut seen := map[string]bool{}
	for provider in catalog {
		assert provider.id in supported_model_providers
		assert !seen[provider.id]
		seen[provider.id] = true
		assert provider.name.len > 0
		assert provider.description.len > 0
		assert provider.base_url.starts_with('https://')
			|| provider.id in ['ollama', 'llama-cpp', 'lmstudio', 'localai', 'vllm']
		assert provider.protocol in ['anthropic', 'gemini', 'openai-compatible']
	}
	assert seen['openai-compatible']
	assert seen['anthropic']
	assert seen['gemini']
	assert seen['deepseek']
	assert seen['openrouter']
	assert seen['ollama']
	ollama := model_provider_info('ollama') or { panic('Ollama missing from catalog') }
	assert !ollama.requires_api_key
	for provider in ['llama-cpp', 'lmstudio', 'localai', 'vllm'] {
		info := model_provider_info(provider) or { panic('Local provider ${provider} missing from catalog') }
		assert !info.requires_api_key
		assert info.protocol == 'openai-compatible'
		assert info.base_url.starts_with('http://127.0.0.1:')
	}
	cloudflare := model_provider_info('cloudflare-workers-ai') or {
		panic('Cloudflare Workers AI missing from catalog')
	}
	assert cloudflare.requires_api_key
	assert cloudflare.base_url.contains('/accounts/YOUR_ACCOUNT_ID/ai/v1')
}

fn test_model_settings_view_exposes_provider_catalog_without_secrets() {
	mut state := new_model_settings_state('')
	state.update(ModelSettingsInput{
		provider: 'groq'
		model:    'fixture-model'
		base_url: 'https://api.groq.com/openai/v1'
		api_key:  'secret-fixture-key'
	}) or { panic(err) }
	view := state.view()
	assert view.active_provider == 'groq'
	assert view.providers.len == supported_model_providers.len
	assert view.profiles['groq'].api_key_saved
	assert !json2.encode(view).contains('secret-fixture-key')
}

fn test_provider_environment_key_uses_catalog_mapping() {
	for provider, key in {
		'deepseek':              'DEEPSEEK_API_KEY'
		'groq':                  'GROQ_API_KEY'
		'openrouter':            'OPENROUTER_API_KEY'
		'xai':                   'XAI_API_KEY'
		'vercel':                'AI_GATEWAY_API_KEY'
		'cloudflare-workers-ai': 'CLOUDFLARE_API_TOKEN'
	} {
		os.setenv(key, 'fixture-${provider}-key', true)
		defer { os.unsetenv(key) }
		assert provider_api_key(provider) or { '' } == 'fixture-${provider}-key'
	}
}

fn test_ollama_profile_builds_a_local_model_config_without_credentials() {
	root := os.join_path(os.temp_dir(), 'veasel-ollama-settings-${uuid.new_v4().str()}')
	os.mkdir_all(os.join_path(root, 'plugins')) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	mut app := new_app(store, os.join_path(root, 'plugins'))
	app.model_settings.update(ModelSettingsInput{
		provider: 'ollama'
		model:    'qwen2.5-coder:7b'
		base_url: 'http://127.0.0.1:11434/v1'
	}) or { panic(err) }
	config := app.model_config() or { panic(err) }
	assert config.provider == 'ollama'
	assert config.model == 'qwen2.5-coder:7b'
	assert config.api_key == ''
	assert config.base_url == 'http://127.0.0.1:11434/v1'
	app.close()
	store.close() or { panic(err) }
}

fn test_provider_model_catalog_parsers() {
	openai_models := parse_provider_model_catalog('openai-compatible',
		'{"data":[{"id":"gpt-5","created":1,"object":"model","owned_by":"openai"},{"id":"fixture-model","name":"Fixture Model"}]}') or {
		panic(err)
	}
	assert openai_models.len == 2
	assert openai_models[0].id == 'gpt-5'
	assert openai_models[0].name == 'gpt-5'
	assert openai_models[1].name == 'Fixture Model'

	claude_models := parse_provider_model_catalog('anthropic',
		'{"data":[{"type":"model","id":"claude-sonnet","display_name":"Claude Sonnet","created_at":"2026-01-01T00:00:00Z"}]}') or {
		panic(err)
	}
	assert claude_models.len == 1
	assert claude_models[0].id == 'claude-sonnet'
	assert claude_models[0].name == 'Claude Sonnet'

	gemini_models := parse_provider_model_catalog('gemini',
		'{"models":[{"name":"models/gemini-2.5-pro","displayName":"Gemini 2.5 Pro","supportedGenerationMethods":["generateContent"]},{"name":"models/text-embedding-004","displayName":"Embedding","supportedGenerationMethods":["embedContent"]}]}') or {
		panic(err)
	}
	assert gemini_models.len == 1
	assert gemini_models[0].id == 'gemini-2.5-pro'
	assert gemini_models[0].name == 'Gemini 2.5 Pro'
}

fn test_provider_model_catalog_rejects_invalid_data_and_deduplicates() {
	models := parse_provider_model_catalog('openai-compatible',
		'{"data":[{"id":"gpt-5"},{"id":"gpt-5"},{"id":""},{"id":"${'x'.repeat(201)}"}]}') or {
		panic(err)
	}
	assert models.len == 1
	assert models[0].id == 'gpt-5'
	parse_provider_model_catalog('gemini', '{invalid') or {
		assert err.msg() == 'model catalog response is invalid'
		return
	}
	assert false
}

fn test_model_settings_persistence_failure_does_not_change_active_configuration() {
	root := os.join_path(os.temp_dir(), 'veasel-model-settings-${uuid.new_v4().str()}')
	blocker := os.join_path(root, 'not-a-directory')
	os.mkdir_all(root) or { panic(err) }
	os.write_file(blocker, 'file blocks the settings directory') or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(blocker, 'model-settings.json')
	mut state := new_model_settings_state(path)
	mut failed := false
	state.update(ModelSettingsInput{
		provider: 'anthropic'
		model:    'claude-sonnet-4-5'
		base_url: 'https://api.anthropic.com/v1'
		api_key:  'must-not-activate'
	}) or {
		failed = true
	}
	assert failed
	assert state.view().active_provider == 'openai-compatible'
	assert state.view().profiles.len == 0
}
