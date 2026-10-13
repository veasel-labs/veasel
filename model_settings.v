module main

import json2
import os
import sync

pub struct ModelProviderInfo {
pub:
	id                string
	name              string
	description       string
	protocol          string
	base_url          string
	environment_key   string
	documentation_url string
	requires_api_key  bool = true
}

fn model_provider_info(provider string) ?ModelProviderInfo {
	for info in model_provider_catalog() {
		if info.id == provider { return info }
	}
	return none
}

struct ModelProfile {
pub:
	model    string
	base_url string
	api_key  string
}

struct PersistedModelSettings {
mut:
	active_provider string
	profiles        map[string]ModelProfile
}

pub struct ModelSettingsView {
pub:
	active_provider      string
	profiles             map[string]ModelProfileView
	providers            []ModelProviderInfo
	configured_providers []string
}

pub struct ModelProfileView {
pub:
	model         string
	base_url      string
	api_key_saved bool
}

struct ModelSettingsInput {
pub:
	provider      string
	model         string
	base_url      string
	api_key       string
	clear_api_key bool
}

// ModelCatalogInput lets a client discover models before saving a provider
// profile. Credentials are accepted only in the request body and are never
// persisted by this operation.
struct ModelCatalogInput {
pub:
	provider      string
	base_url      string
	api_key       string
	clear_api_key bool
}

@[heap]
pub struct ModelSettingsState {
mut:
	mu       sync.Mutex
	path     string
	settings PersistedModelSettings
}

pub fn new_model_settings_state(path string) &ModelSettingsState {
	mut state := &ModelSettingsState{
		path:     path
		settings: PersistedModelSettings{
			active_provider: 'openai-compatible'
			profiles:        map[string]ModelProfile{}
		}
	}
	if path != '' && os.is_file(path) {
		loaded := json2.decode[PersistedModelSettings](os.read_file(path) or { '' }) or { return state }
		if loaded.active_provider in supported_model_providers {
			state.settings = loaded
		}
	}
	return state
}

fn (mut state ModelSettingsState) view() ModelSettingsView {
	state.mu.lock()
	defer { state.mu.unlock() }
	mut profiles := map[string]ModelProfileView{}
	for provider, profile in state.settings.profiles {
		profiles[provider] = ModelProfileView{
			model:         profile.model
			base_url:      profile.base_url
			api_key_saved: profile.api_key.len > 0
		}
	}
	mut configured_providers := []string{}
	for info in model_provider_catalog() {
		profile := state.settings.profiles[info.id] or { ModelProfile{} }
		api_key := non_empty_environment_value('VEASEL_MODEL_API_KEY') or {
			non_empty_environment_value(info.environment_key) or { profile.api_key }
		}
		if api_key.trim_space().len > 0 {
			configured_providers << info.id
		}
	}
	return ModelSettingsView{
		active_provider:      state.settings.active_provider
		profiles:             profiles
		providers:            model_provider_catalog()
		configured_providers: configured_providers
	}
}

fn (mut state ModelSettingsState) update(input ModelSettingsInput) ! {
	provider := input.provider.trim_space()
	if provider !in supported_model_providers {
		return error('unsupported model provider')
	}
	model := input.model.trim_space()
	base_url := secure_endpoint(input.base_url)!
	if model.len == 0 || model.len > 200 || input.base_url.len > 2_048 || input.api_key.len > 4_096 {
		return error('model settings are invalid')
	}
	state.mu.lock()
	defer { state.mu.unlock() }
	previous := state.settings.profiles[provider] or { ModelProfile{} }
	key := if input.clear_api_key {
		''
	} else if input.api_key.len > 0 {
		input.api_key
	} else {
		previous.api_key
	}
	mut profiles := state.settings.profiles.clone()
	profiles[provider] = ModelProfile{ model: model, base_url: base_url, api_key: key }
	updated := PersistedModelSettings{ active_provider: provider, profiles: profiles }
	state.persist(updated)!
	state.settings = updated
}

fn (state &ModelSettingsState) persist(settings PersistedModelSettings) ! {
	if state.path == '' { return }
	os.mkdir_all(os.dir(state.path))!
	temporary_path := '${state.path}.tmp'
	write_private_file(temporary_path, json2.encode(settings))!
	$if !windows {
		os.chmod(temporary_path, 0o600)!
	}
	os.mv(temporary_path, state.path)!
}

fn write_private_file(path string, contents string) ! {
	mut file := os.open_file(path, 'w', 0o600)!
	defer { file.close() }
	$if !windows {
		os.chmod(path, 0o600)!
	}
	file.write_string(contents)!
}

fn (app &App) model_config() !ModelConfig {
	mut state := app.model_settings
	state.mu.lock()
	has_profiles := state.settings.profiles.len > 0
	active_provider := state.settings.active_provider
	provider := if has_profiles {
		active_provider
	} else {
		os.getenv_opt('VEASEL_MODEL_PROVIDER') or { active_provider }
	}
	state.mu.unlock()
	config := app.provider_model_config(provider, os.getenv_opt('VEASEL_MODEL') or { '' })!
	if config.model.trim_space().len == 0 || config.model.len > 200 {
		return error('model is not configured')
	}
	return config
}

fn (app &App) provider_model_config(provider string, fallback_model string) !ModelConfig {
	return app.resolve_provider_model_config(provider, fallback_model, '', '', false)
}

fn (app &App) provider_catalog_model_config(input ModelCatalogInput) !ModelConfig {
	if input.provider.trim_space().len == 0 || input.provider.len > 100 || input.base_url.len > 2_048
		|| input.api_key.len > 4_096 {
		return error('model catalog request is invalid')
	}
	return app.resolve_provider_model_config(input.provider, '', input.base_url, input.api_key,
		input.clear_api_key)
}

fn (app &App) resolve_provider_model_config(provider string, fallback_model string, endpoint_override string,
	key_override string, clear_saved_key bool) !ModelConfig {
	mut state := app.model_settings
	state.mu.lock()
	profile := state.settings.profiles[provider] or { ModelProfile{} }
	state.mu.unlock()
	model := if profile.model.len > 0 { profile.model } else { fallback_model }
	api_key := if key_override.len > 0 {
		key_override
	} else if clear_saved_key {
		provider_api_key(provider) or { '' }
	} else {
		provider_api_key(provider) or { profile.api_key }
	}
	base_url := if endpoint_override.trim_space().len > 0 {
		endpoint_override
	} else if profile.base_url.len > 0 {
		profile.base_url
	} else {
		os.getenv_opt('VEASEL_MODEL_BASE_URL') or {
			info := model_provider_info(provider) or { return error('unsupported model provider') }
			info.base_url
		}
	}
	info := model_provider_info(provider) or { return error('unsupported model provider') }
	if info.requires_api_key && api_key.trim_space().len == 0 {
		return error('model credentials are not configured for ${provider}')
	}
	return ModelConfig{ provider: provider, base_url: secure_endpoint(base_url)!, model: model.trim_space(), api_key: api_key }
}

fn (app &App) configured_model() ?string {
	config := app.model_config() or { return none }
	return config.model
}
