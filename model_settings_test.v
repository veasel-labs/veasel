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
	assert view.profiles['anthropic'].max_output_tokens == 0
	assert !json2.encode(view).contains('secret-token-value')

	mut reloaded := new_model_settings_state(path)
	assert reloaded.view().active_provider == 'anthropic'
	assert reloaded.view().profiles['anthropic'].api_key_saved
	assert reloaded.view().profiles['anthropic'].base_url == 'https://api.anthropic.com/v1'
	assert reloaded.view().profiles['anthropic'].max_output_tokens == 0
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

fn test_model_settings_validate_and_preserve_output_token_budget() {
	mut state := new_model_settings_state('')
	state.update(ModelSettingsInput{
		provider:          'meta'
		model:             'muse-wonder-1.0'
		base_url:          'https://api.meta.ai/v1'
		max_output_tokens: 8192
	}) or { panic(err) }
	state.update(ModelSettingsInput{
		provider: 'meta'
		model:    'muse-wonder-1.0'
		base_url: 'https://api.meta.ai/v1'
		api_key:  'fixture-meta-key'
	}) or { panic(err) }
	assert state.view().profiles['meta'].max_output_tokens == 8192
	for invalid in [-1, 1, 15, 131_073] {
		state.update(ModelSettingsInput{
			provider:          'meta'
			model:             'muse-wonder-1.0'
			base_url:          'https://api.meta.ai/v1'
			max_output_tokens: invalid
		}) or {
			assert err.msg() == 'model settings are invalid'
			continue
		}
		assert false, 'invalid output budget ${invalid} was accepted'
	}
	for valid in [0, 16, 131_072] {
		state.update(ModelSettingsInput{
			provider:          'meta'
			model:             'muse-wonder-1.0'
			base_url:          'https://api.meta.ai/v1'
			max_output_tokens: valid
		}) or { panic(err) }
		assert state.view().profiles['meta'].max_output_tokens == valid
	}
}

fn test_model_settings_view_sanitizes_legacy_or_corrupt_output_budget() {
	mut state := new_model_settings_state('')
	state.settings.profiles['meta'] = ModelProfile{
		model:             'muse-wonder-1.0'
		base_url:          'https://api.meta.ai/v1'
		max_output_tokens: 1
	}
	assert state.view().profiles['meta'].max_output_tokens == 0
}

fn test_model_settings_input_distinguishes_omitted_budget_from_zero() {
	omitted := json2.decode[ModelSettingsInput]('{"provider":"meta","model":"muse-wonder-1.0","base_url":"https://api.meta.ai/v1"}') or {
		panic(err)
	}
	explicit_zero := json2.decode[ModelSettingsInput]('{"provider":"meta","model":"muse-wonder-1.0","base_url":"https://api.meta.ai/v1","max_output_tokens":0}') or {
		panic(err)
	}
	assert (omitted.max_output_tokens or { -1 }) == -1
	assert (explicit_zero.max_output_tokens or { -1 }) == 0
}

fn test_model_settings_reject_unsupported_provider_and_insecure_endpoint() {
	mut state := new_model_settings_state('')
	state.update(ModelSettingsInput{ provider: 'unknown', model: 'x', base_url: 'https://example.com' }) or {
		assert err.msg() == 'unsupported model provider'
		return
	}
	assert false
}

fn test_model_settings_reject_control_bytes_in_model_or_api_key() {
	mut state := new_model_settings_state('')
	state.update(ModelSettingsInput{
		provider: 'openai'
		model:    'gpt\nbad'
		base_url: 'https://api.openai.com/v1'
		api_key:  'sk-ok'
	}) or {
		assert err.msg() == 'model settings are invalid'
		state.update(ModelSettingsInput{
			provider: 'openai'
			model:    'gpt-ok'
			base_url: 'https://api.openai.com/v1'
			api_key:  'sk-\0bad'
		}) or {
			assert err.msg() == 'model settings are invalid'
			state.update(ModelSettingsInput{
				provider: 'openai'
				model:    'gpt-ok'
				base_url: 'https://api.openai.com/v1\nbad'
				api_key:  'sk-ok'
			}) or {
				assert err.msg() == 'model endpoint is invalid'
				return
			}
			assert false
		}
		assert false
	}
	assert false
}

fn test_effective_max_output_tokens_defaults_except_meta() {
	assert effective_max_output_tokens('openai', 0) == max_model_output_tokens
	assert effective_max_output_tokens('anthropic', 0) == max_model_output_tokens
	assert effective_max_output_tokens('gemini', 0) == max_model_output_tokens
	assert effective_max_output_tokens('meta', 0) == 0
	assert effective_max_output_tokens('openai', 2048) == 2048
	assert effective_max_output_tokens('meta', 8192) == 8192
}

fn test_provider_catalog_includes_native_and_openai_compatible_options() {
	catalog := model_provider_catalog()
	assert catalog.len == supported_model_providers.len
	assert catalog.len == 210
	mut seen := map[string]bool{}
	for provider in catalog {
		assert provider.id in supported_model_providers
		assert !seen[provider.id]
		seen[provider.id] = true
		assert provider.name.len > 0
		assert provider.description.len > 0
		assert provider.base_url.starts_with('https://')
			|| provider.id in ['atomic-chat', 'ollama', 'llama-cpp', 'lmstudio', 'localai', 'vllm']
		assert provider.protocol in ['anthropic', 'gemini', 'openai-compatible', 'openai-responses']
	}
	assert seen['openai-compatible']
	assert seen['anthropic']
	assert seen['gemini']
	assert seen['deepseek']
	assert seen['openrouter']
	assert seen['ollama']
	assert seen['atomic-chat']
	assert seen['dashscope']
	assert seen['zai']
	assert seen['meta']
	assert seen['openai']
	assert seen['agentrouter']
	assert seen['aimlapi']
	assert seen['bailing']
	openai := model_provider_info('openai') or { panic('OpenAI missing') }
	assert openai.protocol == 'openai-compatible'
	assert openai.base_url == 'https://api.openai.com/v1'
	assert openai.environment_key == 'OPENAI_API_KEY'
	openai_responses := model_provider_info('openai-responses') or {
		panic('OpenAI Responses preset missing')
	}
	assert openai_responses.protocol == 'openai-responses'
	assert openai_responses.base_url == 'https://api.openai.com/v1'
	assert openai_responses.environment_key == 'OPENAI_API_KEY'
	assert openai_responses.documentation_url == 'https://platform.openai.com/docs/api-reference/responses'
	meta := model_provider_info('meta') or { panic('Meta Model API missing') }
	assert meta.name == 'Meta Model API'
	assert meta.protocol == 'openai-responses'
	assert meta.base_url == 'https://api.meta.ai/v1'
	assert meta.environment_key == 'MODEL_API_KEY'
	assert meta.documentation_url == 'https://dev.meta.ai/docs/coding-agents'
	assert seen['302-ai']
	assert seen['gmi-cloud']
	assert seen['minimax']
	assert seen['scaleway']
	for provider in ['baseten', 'cortecs', 'digitalocean', 'frogbot', 'helicone', 'io-net', 'llmgateway',
		'ollama-cloud', 'zenmux'] {
		assert seen[provider]
		info := model_provider_info(provider) or { panic('${provider} missing') }
		assert info.protocol == 'openai-compatible'
		assert info.base_url.starts_with('https://')
		assert info.environment_key != ''
	}
	for provider in ['abacus', 'above', 'ai-router', 'ai21', 'alibaba', 'alibaba-coding-plan',
		'clarifai', 'cline-pass', 'crusoe', 'friendli', 'inference', 'kilo', 'llama', 'model-oracle-ai',
		'modelscope', 'modal', 'moonshotai-cn', 'nano-gpt', 'nearai', 'oci', 'poe', 'poolside',
		'qiniu-ai', 'sarvam', 'sensenova', 'siliconflow-cn', 'stackit', 'stepfun-ai', 'tencent-tokenhub',
		'tinfoil', 'upstage', 'volcengine', 'vultr', 'xiaomi-token-plan-cn', 'zai-coding-plan',
		'zhipuai-coding-plan'] {
		assert seen[provider]
		info := model_provider_info(provider) or { panic('${provider} missing') }
		assert info.protocol == 'openai-compatible'
		assert info.base_url.starts_with('https://')
		assert info.environment_key != ''
		assert info.documentation_url.starts_with('https://')
	}
	provider_302 := model_provider_info('302-ai') or { panic('302.AI missing') }
	assert provider_302.base_url == 'https://api.302.ai/v1'
	assert provider_302.environment_key == '302AI_API_KEY'
	assert provider_302.protocol == 'openai-compatible'
	gmi_cloud := model_provider_info('gmi-cloud') or { panic('GMI Cloud missing') }
	assert gmi_cloud.base_url == 'https://api.gmi-serving.com/v1'
	assert gmi_cloud.environment_key == 'GMI_API_KEY'
	assert gmi_cloud.protocol == 'openai-compatible'
	minimax := model_provider_info('minimax') or { panic('MiniMax missing') }
	assert minimax.base_url == 'https://api.minimax.io/v1'
	assert minimax.environment_key == 'MINIMAX_API_KEY'
	scaleway := model_provider_info('scaleway') or { panic('Scaleway missing') }
	assert scaleway.base_url == 'https://api.scaleway.ai/v1'
	assert scaleway.environment_key == 'SCW_SECRET_KEY'
	atomic_chat := model_provider_info('atomic-chat') or { panic('Atomic Chat missing') }
	assert atomic_chat.base_url == 'http://127.0.0.1:1337/v1'
	assert !atomic_chat.requires_api_key
	dashscope := model_provider_info('dashscope') or { panic('DashScope missing') }
	assert dashscope.environment_key == 'DASHSCOPE_API_KEY'
	assert dashscope.protocol == 'openai-compatible'
	zai := model_provider_info('zai') or { panic('Z.AI missing') }
	assert zai.base_url == 'https://api.z.ai/api/paas/v4'
	assert zai.protocol == 'openai-compatible'
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

fn test_provider_catalog_ids_are_declared_in_openapi() {
	openapi := os.read_file('docs/openapi.yaml') or { panic(err) }
	assert openapi.contains('operationId: discoverProviderModels')
	assert openapi.contains("$ref: '#/components/schemas/ModelCatalogInput'")
	assert openapi.contains('Optional transient key used for this discovery request')
	assert openapi.contains('configured_providers:')
	assert openapi.contains('Chat-and-tool-compatible models exposed by the provider adapter')
	for provider in supported_model_providers {
		assert openapi.contains('- ${provider}')
	}
	assert openapi.contains('documentation_url: { type: string }')
	assert openapi.contains('openai-responses')
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
	assert 'groq' in view.configured_providers
	assert !json2.encode(view).contains('secret-fixture-key')
}

fn test_model_settings_view_marks_environment_credentials_without_exposing_them() {
	prior := os.getenv('MODEL_API_KEY')
	os.setenv('MODEL_API_KEY', 'fixture-environment-secret', true)
	defer {
		if prior == '' {
			os.unsetenv('MODEL_API_KEY')
		} else {
			os.setenv('MODEL_API_KEY', prior, true)
		}
	}
	state := new_model_settings_state('')
	view := state.view()
	assert 'meta' in view.configured_providers
	assert !json2.encode(view).contains('fixture-environment-secret')
}

fn test_provider_environment_key_uses_catalog_mapping() {
	for provider, key in {
		'deepseek':              'DEEPSEEK_API_KEY'
		'groq':                  'GROQ_API_KEY'
		'openrouter':            'OPENROUTER_API_KEY'
		'xai':                   'XAI_API_KEY'
		'vercel':                'AI_GATEWAY_API_KEY'
		'cloudflare-workers-ai': 'CLOUDFLARE_API_TOKEN'
		'dashscope':             'DASHSCOPE_API_KEY'
		'zai':                   'ZAI_API_KEY'
		'302-ai':                '302AI_API_KEY'
		'gmi-cloud':             'GMI_API_KEY'
		'minimax':               'MINIMAX_API_KEY'
		'scaleway':              'SCW_SECRET_KEY'
		'baseten':               'BASETEN_API_KEY'
		'cortecs':               'CORTECS_API_KEY'
		'digitalocean':          'DIGITALOCEAN_ACCESS_TOKEN'
		'frogbot':               'FROGBOT_API_KEY'
		'helicone':              'HELICONE_API_KEY'
		'io-net':                'IOINTELLIGENCE_API_KEY'
		'llmgateway':            'LLMGATEWAY_API_KEY'
		'ollama-cloud':          'OLLAMA_API_KEY'
		'zenmux':                'ZENMUX_API_KEY'
	} {
		os.setenv(key, 'fixture-${provider}-key', true)
		defer { os.unsetenv(key) }
		assert provider_api_key(provider) or { '' } == 'fixture-${provider}-key'
	}
	for info in model_provider_catalog() {
		if info.documentation_url == '' {
			continue
		}
		prior := os.getenv(info.environment_key)
		os.setenv(info.environment_key, 'fixture-${info.id}-key', true)
		assert provider_api_key(info.id) or { '' } == 'fixture-${info.id}-key'
		if prior == '' {
			os.unsetenv(info.environment_key)
		} else {
			os.setenv(info.environment_key, prior, true)
		}
	}
}

fn test_provider_api_key_ignores_empty_environment_values() {
	prior_shared_key := os.getenv('VEASEL_MODEL_API_KEY')
	prior_provider_key := os.getenv('MODEL_API_KEY')
	os.setenv('VEASEL_MODEL_API_KEY', '', true)
	os.setenv('MODEL_API_KEY', '', true)
	defer {
		if prior_shared_key == '' {
			os.unsetenv('VEASEL_MODEL_API_KEY')
		} else {
			os.setenv('VEASEL_MODEL_API_KEY', prior_shared_key, true)
		}
		if prior_provider_key == '' {
			os.unsetenv('MODEL_API_KEY')
		} else {
			os.setenv('MODEL_API_KEY', prior_provider_key, true)
		}
	}
	assert provider_api_key('meta') or { '' } == ''
}

fn test_provider_https_uses_system_ca_bundle_and_http_needs_none() {
	prior := os.getenv('SSL_CERT_FILE')
	os.unsetenv('SSL_CERT_FILE')
	defer {
		if prior == '' {
			os.unsetenv('SSL_CERT_FILE')
		} else {
			os.setenv('SSL_CERT_FILE', prior, true)
		}
	}
	assert provider_tls_verify_path('http://127.0.0.1:4097/v1')! == ''
	$if windows {
		assert provider_tls_verify_path('https://api.meta.ai/v1')! == ''
		assert provider_tls_verify_path('HTTPS://api.meta.ai/v1')! == ''
	} $else {
		ca_bundle := provider_tls_verify_path('https://api.meta.ai/v1')!
		assert os.is_file(ca_bundle)
		assert provider_tls_verify_path('HTTPS://api.meta.ai/v1')! == ca_bundle
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

fn test_provider_output_budget_uses_provider_default_and_custom_limits() {
	root := os.join_path(os.temp_dir(), 'veasel-output-budget-${uuid.new_v4().str()}')
	os.mkdir_all(os.join_path(root, 'plugins')) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	mut app := new_app(store, os.join_path(root, 'plugins'))
	app.model_settings.update(ModelSettingsInput{
		provider: 'meta'
		model:    'muse-wonder-1.0'
		base_url: 'https://api.meta.ai/v1'
		api_key:  'fixture-meta-key'
	}) or { panic(err) }
	meta_default := app.model_config() or { panic(err) }
	assert meta_default.max_output_tokens == 0
	app.model_settings.update(ModelSettingsInput{
		provider:          'meta'
		model:             'muse-wonder-1.0'
		base_url:          'https://api.meta.ai/v1'
		api_key:           'fixture-meta-key'
		max_output_tokens: 8192
	}) or { panic(err) }
	assert (app.model_config() or { panic(err) }).max_output_tokens == 8192
	app.model_settings.update(ModelSettingsInput{
		provider: 'anthropic'
		model:    'claude-sonnet-4-5'
		base_url: 'https://api.anthropic.com/v1'
		api_key:  'fixture-anthropic-key'
	}) or { panic(err) }
	assert (app.model_config() or { panic(err) }).max_output_tokens == max_model_output_tokens
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
	meta_models := parse_provider_model_catalog('openai-responses',
		'{"data":[{"id":"muse-wonder-1.0"},{"id":"muse-spark-1.3"}]}') or { panic(err) }
	assert meta_models.map(it.id) == ['muse-wonder-1.0', 'muse-spark-1.3']
}

fn test_meta_model_discovery_only_offers_coding_chat_families() {
	models := [
		'muse-wonder-1.0',
		'muse-spark-1.3',
		'muse-spark-1.3-contributor',
		'muse-image-1.0',
		'muse-voice-transcribe-1.0',
		'sam-3.1',
	].map(ModelCatalogEntry{ id: it, name: it })

	meta_models := filter_provider_chat_models('meta', models)
	assert meta_models.map(it.id) == ['muse-wonder-1.0', 'muse-spark-1.3', 'muse-spark-1.3-contributor']
	assert filter_provider_chat_models('openai', models) == models
}

fn test_provider_model_discovery_accepts_unsaved_credentials_without_persisting_them() {
	root := os.join_path(os.temp_dir(), 'veasel-model-discovery-${uuid.new_v4().str()}')
	os.mkdir_all(os.join_path(root, 'plugins')) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	mut app := new_app(store, os.join_path(root, 'plugins'))
	config := app.provider_catalog_model_config(ModelCatalogInput{
		provider: 'meta'
		base_url: 'http://127.0.0.1:19123/v1'
		api_key:  'transient-discovery-key'
	}) or { panic(err) }
	assert config.provider == 'meta'
	assert config.base_url == 'http://127.0.0.1:19123/v1'
	assert config.api_key == 'transient-discovery-key'
	assert app.model_settings.view().profiles.len == 0
	assert !json2.encode(app.model_settings.view()).contains('transient-discovery-key')
	app.close()
	store.close() or { panic(err) }
}

fn test_resolve_provider_model_config_prefers_saved_key_over_environment() {
	root := os.join_path(os.temp_dir(), 'veasel-saved-key-wins-${uuid.new_v4().str()}')
	os.mkdir_all(os.join_path(root, 'plugins')) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	prior_environment_key := os.getenv('MODEL_API_KEY')
	prior_shared_key := os.getenv('VEASEL_MODEL_API_KEY')
	os.unsetenv('VEASEL_MODEL_API_KEY')
	os.setenv('MODEL_API_KEY', 'fixture-environment-key', true)
	defer {
		if prior_shared_key == '' {
			os.unsetenv('VEASEL_MODEL_API_KEY')
		} else {
			os.setenv('VEASEL_MODEL_API_KEY', prior_shared_key, true)
		}
		if prior_environment_key == '' {
			os.unsetenv('MODEL_API_KEY')
		} else {
			os.setenv('MODEL_API_KEY', prior_environment_key, true)
		}
	}
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	mut app := new_app(store, os.join_path(root, 'plugins'))
	app.model_settings.update(ModelSettingsInput{
		provider: 'meta'
		model:    'muse-saved-model'
		base_url: 'https://api.meta.ai/v1'
		api_key:  'fixture-saved-key'
	}) or { panic(err) }
	config := app.provider_model_config('meta', '') or { panic(err) }
	assert config.api_key == 'fixture-saved-key'
	assert config.model == 'muse-saved-model'
	view := app.model_settings.view()
	assert 'meta' in view.configured_providers
	assert !json2.encode(view).contains('fixture-saved-key')
	assert !json2.encode(view).contains('fixture-environment-key')
	app.close()
	store.close() or { panic(err) }
}

fn test_provider_model_discovery_uses_transient_credentials_before_saved_or_environment_keys() {
	root := os.join_path(os.temp_dir(), 'veasel-model-discovery-credentials-${uuid.new_v4().str()}')
	os.mkdir_all(os.join_path(root, 'plugins')) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	prior_environment_key := os.getenv('MODEL_API_KEY')
	prior_shared_key := os.getenv('VEASEL_MODEL_API_KEY')
	os.unsetenv('VEASEL_MODEL_API_KEY')
	os.setenv('MODEL_API_KEY', 'fixture-environment-key', true)
	defer {
		if prior_shared_key == '' {
			os.unsetenv('VEASEL_MODEL_API_KEY')
		} else {
			os.setenv('VEASEL_MODEL_API_KEY', prior_shared_key, true)
		}
		if prior_environment_key == '' {
			os.unsetenv('MODEL_API_KEY')
		} else {
			os.setenv('MODEL_API_KEY', prior_environment_key, true)
		}
	}
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	mut app := new_app(store, os.join_path(root, 'plugins'))
	app.model_settings.update(ModelSettingsInput{
		provider: 'meta'
		model:    'muse-saved-model'
		base_url: 'https://api.meta.ai/v1'
		api_key:  'fixture-saved-key'
	}) or { panic(err) }
	config := app.provider_catalog_model_config(ModelCatalogInput{
		provider: 'meta'
		base_url: 'http://127.0.0.1:19123/v1'
		api_key:  'fixture-transient-key'
	}) or { panic(err) }
	assert config.api_key == 'fixture-transient-key'
	assert config.base_url == 'http://127.0.0.1:19123/v1'
	view := app.model_settings.view()
	assert view.profiles['meta'].model == 'muse-saved-model'
	assert view.profiles['meta'].base_url == 'https://api.meta.ai/v1'
	assert !json2.encode(view).contains('fixture-transient-key')
	assert !json2.encode(view).contains('fixture-environment-key')
	os.unsetenv('MODEL_API_KEY')
	mut clear_rejected := false
	app.provider_catalog_model_config(ModelCatalogInput{
		provider:      'meta'
		base_url:      'http://127.0.0.1:19123/v1'
		clear_api_key: true
	}) or {
		clear_rejected = true
		assert err.msg().contains('credentials are not configured')
	}
	assert clear_rejected
	app.close()
	store.close() or { panic(err) }
}

fn test_provider_model_discovery_rejects_insecure_or_oversized_overrides() {
	root := os.join_path(os.temp_dir(), 'veasel-model-discovery-validation-${uuid.new_v4().str()}')
	os.mkdir_all(os.join_path(root, 'plugins')) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	mut app := new_app(store, os.join_path(root, 'plugins'))
	app.provider_catalog_model_config(ModelCatalogInput{
		provider: 'meta'
		base_url: 'http://192.0.2.1/v1'
		api_key:  'fixture-key'
	}) or {
		assert err.msg().contains('must use HTTPS or loopback HTTP')
		mut oversized_rejected := false
		app.provider_catalog_model_config(ModelCatalogInput{
			provider: 'meta'
			base_url: 'https://models.example.com/${'x'.repeat(2_100)}'
			api_key:  'fixture-key'
		}) or {
			oversized_rejected = true
			assert err.msg() == 'model catalog request is invalid'
		}
		assert oversized_rejected
		app.close()
		store.close() or { panic(err) }
		return
	}
	assert false
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
