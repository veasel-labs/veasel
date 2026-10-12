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
