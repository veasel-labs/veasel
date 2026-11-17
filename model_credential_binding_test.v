module main

import os
import uuid

// Saved and environment credentials must only reach the endpoint they were
// configured for. These tests use synthetic keys and never open a socket: the
// resolved ModelConfig is exactly what fetch_provider_models and the chat
// adapters send, so asserting on it proves where a key would go.

const binding_saved_key = 'synthetic-saved-key-0001'
const binding_env_key = 'synthetic-env-key-0002'
const binding_override_key = 'synthetic-override-key-0003'
const binding_attacker_url = 'https://attacker.example/v1'

fn binding_test_app(root string) (&Store, &App) {
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	plugin_dir := os.join_path(root, 'plugins')
	os.mkdir_all(plugin_dir) or { panic(err) }
	app := new_app(store, plugin_dir)
	return store, app
}

fn binding_root() string {
	root := os.join_path(os.temp_dir(), 'veasel-cred-binding-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	return root
}

fn binding_save_openai(app &App, base_url string) {
	mut state := app.model_settings
	state.update(ModelSettingsInput{
		provider: 'openai'
		model:    'gpt-5'
		base_url: base_url
		api_key:  binding_saved_key
	}) or { panic(err) }
}

fn test_catalog_request_never_sends_saved_key_to_caller_endpoint() {
	root := binding_root()
	mut store, app := binding_test_app(root)
	defer {
		app.close()
		store.close() or {}
		os.rmdir_all(root) or {}
	}
	binding_save_openai(app, 'https://api.openai.com/v1')
	config := app.provider_catalog_model_config(ModelCatalogInput{
		provider: 'openai'
		base_url: binding_attacker_url
	}) or {
		assert err.msg().contains('API key')
		return
	}
	assert config.api_key != binding_saved_key
	assert config.api_key == ''
}

fn test_catalog_request_never_sends_environment_key_to_caller_endpoint() {
	root := binding_root()
	mut store, app := binding_test_app(root)
	prior := os.getenv_opt('VEASEL_MODEL_API_KEY')
	os.setenv('VEASEL_MODEL_API_KEY', binding_env_key, true)
	defer {
		if value := prior {
			os.setenv('VEASEL_MODEL_API_KEY', value, true)
		} else {
			os.unsetenv('VEASEL_MODEL_API_KEY')
		}
		app.close()
		store.close() or {}
		os.rmdir_all(root) or {}
	}
	config := app.provider_catalog_model_config(ModelCatalogInput{
		provider: 'openai'
		base_url: binding_attacker_url
	}) or {
		assert err.msg().contains('API key')
		return
	}
	assert config.api_key != binding_env_key
}

fn test_catalog_request_with_explicit_key_uses_only_that_key() {
	root := binding_root()
	mut store, app := binding_test_app(root)
	defer {
		app.close()
		store.close() or {}
		os.rmdir_all(root) or {}
	}
	binding_save_openai(app, 'https://api.openai.com/v1')
	config := app.provider_catalog_model_config(ModelCatalogInput{
		provider: 'openai'
		base_url: binding_attacker_url
		api_key:  binding_override_key
	}) or { panic(err) }
	assert config.api_key == binding_override_key
	assert config.base_url == binding_attacker_url
}

fn test_catalog_request_keeps_saved_key_for_trusted_endpoints() {
	root := binding_root()
	mut store, app := binding_test_app(root)
	defer {
		app.close()
		store.close() or {}
		os.rmdir_all(root) or {}
	}
	// Saved custom endpoint: discovery with the same endpoint (even with a
	// trailing slash or different host case) keeps the saved key.
	binding_save_openai(app, 'https://llm.corp.example/v1')
	for url in ['', 'https://llm.corp.example/v1', 'https://llm.corp.example/v1/',
		'HTTPS://LLM.Corp.Example/v1'] {
		config := app.provider_catalog_model_config(ModelCatalogInput{
			provider: 'openai'
			base_url: url
		}) or { panic('${url}: ${err}') }
		assert config.api_key == binding_saved_key
	}
	// Catalog default endpoint is trusted for the provider's key.
	binding_save_openai(app, 'https://api.openai.com/v1')
	config := app.provider_catalog_model_config(ModelCatalogInput{
		provider: 'openai'
		base_url: 'https://api.openai.com/v1'
	}) or { panic(err) }
	assert config.api_key == binding_saved_key
}

fn test_catalog_request_for_keyless_local_provider_accepts_custom_loopback() {
	root := binding_root()
	mut store, app := binding_test_app(root)
	defer {
		app.close()
		store.close() or {}
		os.rmdir_all(root) or {}
	}
	config := app.provider_catalog_model_config(ModelCatalogInput{
		provider: 'ollama'
		base_url: 'http://127.0.0.1:9999/v1'
	}) or { panic(err) }
	assert config.base_url == 'http://127.0.0.1:9999/v1'
	assert config.api_key == ''
}

fn test_saving_new_endpoint_without_key_drops_previous_key() {
	mut state := new_model_settings_state('')
	state.update(ModelSettingsInput{
		provider: 'openai'
		model:    'gpt-5'
		base_url: 'https://api.openai.com/v1'
		api_key:  binding_saved_key
	}) or { panic(err) }
	// Same endpoint, blank key: key preserved.
	state.update(ModelSettingsInput{
		provider: 'openai'
		model:    'gpt-5-mini'
		base_url: 'https://api.openai.com/v1/'
	}) or { panic(err) }
	assert state.settings.profiles['openai'].api_key == binding_saved_key
	// Different endpoint, blank key: the old key must not follow the endpoint.
	state.update(ModelSettingsInput{
		provider: 'openai'
		model:    'gpt-5-mini'
		base_url: binding_attacker_url
	}) or { panic(err) }
	assert state.settings.profiles['openai'].api_key == ''
	// Different endpoint with its own key: allowed.
	state.update(ModelSettingsInput{
		provider: 'openai'
		model:    'gpt-5-mini'
		base_url: 'https://llm.corp.example/v1'
		api_key:  binding_override_key
	}) or { panic(err) }
	assert state.settings.profiles['openai'].api_key == binding_override_key
}

fn test_model_endpoints_match_normalizes_equivalent_urls() {
	assert model_endpoints_match('https://api.openai.com/v1', 'https://API.openai.com/v1/')
	assert model_endpoints_match('http://127.0.0.1:11434/v1', 'http://127.0.0.1:11434/v1')
	assert !model_endpoints_match('https://api.openai.com/v1', 'https://api.openai.com.evil.example/v1')
	assert !model_endpoints_match('https://api.openai.com/v1', 'http://api.openai.com/v1')
	assert !model_endpoints_match('https://api.openai.com/v1', 'https://api.openai.com:8443/v1')
	assert !model_endpoints_match('https://api.openai.com/v1', 'https://api.openai.com/v2')
	assert !model_endpoints_match('', '')
}
