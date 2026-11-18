module main

import json2
import os
import net.urllib
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
	model             string
	base_url          string
	api_key           string
	max_output_tokens int
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
pub mut:
	// True only when the same resolution a chat turn uses (saved profile,
	// then environment) yields a usable provider, model, and credential.
	// Set by App.model_settings_view; state.view alone leaves it false.
	model_ready bool
}

pub struct ModelProfileView {
pub:
	model             string
	base_url          string
	api_key_saved     bool
	max_output_tokens int
}

struct ModelSettingsInput {
pub:
	provider          string
	model             string
	base_url          string
	api_key           string
	clear_api_key     bool
	max_output_tokens ?int
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
		max_output_tokens := if valid_max_output_tokens(profile.max_output_tokens) {
			profile.max_output_tokens
		} else {
			0
		}
		profiles[provider] = ModelProfileView{
			model:             profile.model
			base_url:          profile.base_url
			api_key_saved:     profile.api_key.len > 0
			max_output_tokens: max_output_tokens
		}
	}
	mut configured_providers := []string{}
	for info in model_provider_catalog() {
		profile := state.settings.profiles[info.id] or { ModelProfile{} }
		// Saved profile keys win over environment variables for the same provider.
		api_key := if profile.api_key.trim_space().len > 0 {
			profile.api_key
		} else {
			non_empty_environment_value('VEASEL_MODEL_API_KEY') or {
				non_empty_environment_value(info.environment_key) or { '' }
			}
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
	if model.len == 0 || model.len > 200 || input.base_url.len > 2_048 || input.api_key.len > 4_096
		|| model_settings_text_has_unsafe_controls(model)
		|| model_settings_text_has_unsafe_controls(input.api_key) {
		return error('model settings are invalid')
	}
	state.mu.lock()
	defer { state.mu.unlock() }
	previous := state.settings.profiles[provider] or { ModelProfile{} }
	max_output_tokens := input.max_output_tokens or { previous.max_output_tokens }
	if !valid_max_output_tokens(max_output_tokens) {
		return error('model settings are invalid')
	}
	key := if input.clear_api_key {
		''
	} else if input.api_key.len > 0 {
		input.api_key
	} else if model_endpoints_match(if previous.base_url.len > 0 {
		previous.base_url
	} else {
		trusted_catalog_endpoint(provider)
	}, base_url) || model_endpoints_match(trusted_catalog_endpoint(provider), base_url) {
		previous.api_key
	} else {
		// A saved key never follows the profile to a different endpoint.
		''
	}
	mut profiles := state.settings.profiles.clone()
	profiles[provider] = ModelProfile{
		model:             model
		base_url:          base_url
		api_key:           key
		max_output_tokens: max_output_tokens
	}
	updated := PersistedModelSettings{ active_provider: provider, profiles: profiles }
	state.persist(updated)!
	state.settings = updated
}

fn (state &ModelSettingsState) persist(settings PersistedModelSettings) ! {
	if state.path == '' { return }
	ensure_directory(os.dir(state.path))!
	write_private_file_atomic(state.path, json2.encode(settings))!
}

// write_private_file_atomic replaces `path` with `contents`, readable only by
// the owner from the moment the file exists:
//   * a stale or attacker-planted `<path>.tmp` (including a symlink) is removed
//     first, so the write can never be redirected onto another file;
//   * the temp file is created with mode 0600 (open(2) mode, so there is no
//     write-then-chmod window), then chmod'd and verified to be exactly 0600;
//   * rename(2) replaces the target (and any symlink at it) atomically.
// Any failure returns an error and deletes the temp file (fail closed).
// Windows has no POSIX mode bits: the file inherits the ACL of its parent
// directory, which is not checked here. See docs/security/threat-model.md.
fn write_private_file_atomic(path string, contents string) ! {
	temporary_path := '${path}.tmp'
	if os.exists(temporary_path) || os.is_link(temporary_path) {
		os.rm(temporary_path)!
	}
	write_private_file(temporary_path, contents) or {
		os.rm(temporary_path) or {}
		return err
	}
	os.mv(temporary_path, path) or {
		os.rm(temporary_path) or {}
		return err
	}
}

// trusted_catalog_endpoint returns the catalog base URL for a provider, or ''.
fn trusted_catalog_endpoint(provider string) string {
	info := model_provider_info(provider) or { return '' }
	return info.base_url
}

fn model_endpoint_is_trusted_for_stored_key(provider string, endpoint string, saved_endpoint string) bool {
	if model_endpoints_match(trusted_catalog_endpoint(provider), endpoint)
		|| model_endpoints_match(saved_endpoint, endpoint) {
		return true
	}
	if operator_endpoint := non_empty_environment_value('VEASEL_MODEL_BASE_URL') {
		return model_endpoints_match(operator_endpoint, endpoint)
	}
	return false
}

fn model_endpoints_match(a string, b string) bool {
	left := a.trim_space().trim_right('/')
	right := b.trim_space().trim_right('/')
	if left.len == 0 || right.len == 0 {
		return false
	}
	pa := urllib.parse(left) or { return false }
	pb := urllib.parse(right) or { return false }
	return pa.scheme.to_lower() == pb.scheme.to_lower() && pa.host.to_lower() == pb.host.to_lower()
		&& pa.path == pb.path
}

fn write_private_file(path string, contents string) ! {
	mut file := os.open_file(path, 'w', 0o600)!
	defer { file.close() }
	$if !windows {
		os.chmod(path, 0o600)!
		if int(os.inode(path).bitmask()) & 0o777 != 0o600 {
			return error('private file permissions could not be enforced')
		}
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

// model_settings_view is the client-facing settings payload: the redacted
// state view plus whether a chat turn could actually run right now, judged
// by model_config itself so the answer can never drift from turn behavior.
fn (app &App) model_settings_view() ModelSettingsView {
	mut state := app.model_settings
	mut view := state.view()
	_ := app.model_config() or { return view }
	view.model_ready = true
	return view
}

fn (app &App) model_config_for_session(session_id string) !ModelConfig {
	mut config := app.model_config()!
	config.session_id = session_id
	return config
}

fn (app &App) provider_model_config(provider string, fallback_model string) !ModelConfig {
	return app.resolve_provider_model_config(provider, fallback_model, '', '', false)
}

// provider_model_config_for_target resolves credentials and endpoint settings
// from the configured provider profile while honoring an explicit per-run
// model selection. Provider/model overrides never mutate the global active
// profile.
fn (app &App) provider_model_config_for_target(provider string, model string) !ModelConfig {
	selected_model := model.trim_space()
	if selected_model.len == 0 || selected_model.len > 200
		|| model_settings_text_has_unsafe_controls(selected_model) {
		return error('selected model is invalid')
	}
	configured := app.resolve_provider_model_config(provider, '', '', '', false)!
	return ModelConfig{
		provider:          configured.provider
		base_url:          configured.base_url
		model:             selected_model
		api_key:           configured.api_key
		max_output_tokens: configured.max_output_tokens
	}
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
	// Installed-CLI providers (ADR-0001 dual plane) have no HTTP endpoint
	// or API key: auth lives in the CLI itself. Resolve them here so they
	// are selectable exactly like catalog providers; the turn dispatch
	// routes them to the CLI runner, never to the HTTP adapters.
	if _ := provider_cli_by_id(provider) {
		cli_model := model.trim_space()
		if cli_model.len > 200 || model_settings_text_has_unsafe_controls(cli_model) {
			return error('model settings are invalid')
		}
		return ModelConfig{
			provider: provider
			model:    if cli_model.len > 0 { cli_model } else { 'default' }
		}
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
	// Credential-to-endpoint binding: a saved or environment key is attached
	// only when the effective endpoint is one the operator already trusts for
	// this provider (catalog default, saved profile endpoint, or the operator's
	// VEASEL_MODEL_BASE_URL). Any other endpoint needs its own key in the same
	// request; the stored key is never sent there.
	// A saved key is bound to the endpoint it was saved with (the update path
	// drops it when that endpoint changes). An environment key is bound ONLY to
	// the catalog/operator endpoint: a caller who saves their own endpoint must
	// never receive it, so the saved endpoint does not make it trusted.
	trusted := model_endpoint_is_trusted_for_stored_key(provider, base_url, profile.base_url)
	env_trusted := model_endpoint_is_trusted_for_stored_key(provider, base_url, '')
	// Precedence: transient override → saved profile key → environment → none.
	// Clearing a saved key intentionally falls back to environment only.
	environment_key := if env_trusted { provider_api_key(provider) or { '' } } else { '' }
	api_key := if key_override.len > 0 {
		key_override
	} else if clear_saved_key {
		environment_key
	} else if trusted && profile.api_key.trim_space().len > 0 {
		profile.api_key
	} else {
		environment_key
	}
	if info.requires_api_key && api_key.trim_space().len == 0 {
		if !trusted {
			return error('model credentials are not configured for ${provider} at this endpoint; enter an API key with the custom endpoint (saved credentials are only used with their own endpoint)')
		}
		return error('model credentials are not configured for ${provider}')
	}
	// Empty model is allowed here so catalog discovery can resolve credentials
	// and endpoints before a model ID is chosen. model_config() still rejects
	// an empty model before any completion request.
	resolved_model := model.trim_space()
	if resolved_model.len > 200 || model_settings_text_has_unsafe_controls(resolved_model)
		|| model_settings_text_has_unsafe_controls(api_key) {
		return error('model settings are invalid')
	}
	return ModelConfig{
		provider:          provider
		base_url:          secure_endpoint(base_url)!
		model:             resolved_model
		api_key:           api_key
		max_output_tokens: effective_max_output_tokens(provider, profile.max_output_tokens)
	}
}

fn effective_max_output_tokens(provider string, configured int) int {
	if valid_max_output_tokens(configured) && configured > 0 {
		return configured
	}
	if provider == 'meta' {
		// Meta Responses omits max_output_tokens so the provider applies its own limit.
		return 0
	}
	return max_model_output_tokens
}

fn model_settings_text_has_unsafe_controls(value string) bool {
	for c in value {
		if c < 32 || c == 127 {
			return true
		}
	}
	return false
}

fn valid_max_output_tokens(value int) bool {
	return value == 0 || value >= min_configured_output_tokens
		&& value <= max_configured_output_tokens
}

const no_model_configured_message = 'No model provider is configured. Run `veasel config model set --provider <id> --model <name> --api-key <key>`, or set VEASEL_MODEL_PROVIDER, VEASEL_MODEL and VEASEL_MODEL_API_KEY, then retry.'

fn (app &App) configured_model() ?string {
	config := app.model_config() or { return none }
	return config.model
}
