module main

import json2
import os
import sync

const supported_model_providers = ['openai-compatible', 'openai', 'anthropic', 'gemini', 'deepseek',
	'groq', 'together', 'fireworks', 'mistral', 'openrouter', 'xai', 'cerebras', 'perplexity',
	'deepinfra', 'venice', 'ollama', 'hyperbolic', 'moonshot', 'nvidia', 'siliconflow', 'sambanova',
	'novita', 'nebius', 'huggingface', 'vercel', 'cloudflare-workers-ai', 'llama-cpp', 'lmstudio',
	'localai', 'vllm', 'atomic-chat', 'dashscope', 'zai']

pub struct ModelProviderInfo {
pub:
	id               string
	name             string
	description      string
	protocol         string
	base_url         string
	environment_key  string
	requires_api_key bool = true
}

fn model_provider_catalog() []ModelProviderInfo {
	return [
		ModelProviderInfo{ id: 'dashscope', name: 'Alibaba Cloud Model Studio', description: 'Qwen and hosted models · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'https://dashscope-us.aliyuncs.com/compatible-mode/v1', environment_key: 'DASHSCOPE_API_KEY' },
		ModelProviderInfo{ id: 'anthropic', name: 'Anthropic', description: 'Claude models · native Messages API', protocol: 'anthropic', base_url: 'https://api.anthropic.com/v1', environment_key: 'ANTHROPIC_API_KEY' },
		ModelProviderInfo{ id: 'atomic-chat', name: 'Atomic Chat', description: 'Local models · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'http://127.0.0.1:1337/v1', requires_api_key: false },
		ModelProviderInfo{ id: 'cerebras', name: 'Cerebras', description: 'Fast inference · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'https://api.cerebras.ai/v1', environment_key: 'CEREBRAS_API_KEY' },
		ModelProviderInfo{ id: 'cloudflare-workers-ai', name: 'Cloudflare Workers AI', description: 'Cloudflare hosted models · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'https://api.cloudflare.com/client/v4/accounts/YOUR_ACCOUNT_ID/ai/v1', environment_key: 'CLOUDFLARE_API_TOKEN' },
		ModelProviderInfo{ id: 'deepinfra', name: 'DeepInfra', description: 'Hosted open models · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'https://api.deepinfra.com/v1/openai', environment_key: 'DEEPINFRA_API_KEY' },
		ModelProviderInfo{ id: 'deepseek', name: 'DeepSeek', description: 'DeepSeek models · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'https://api.deepseek.com/v1', environment_key: 'DEEPSEEK_API_KEY' },
		ModelProviderInfo{ id: 'fireworks', name: 'Fireworks AI', description: 'Open models · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'https://api.fireworks.ai/inference/v1', environment_key: 'FIREWORKS_API_KEY' },
		ModelProviderInfo{ id: 'gemini', name: 'Google Gemini', description: 'Gemini models · native Google Generative Language API', protocol: 'gemini', base_url: 'https://generativelanguage.googleapis.com/v1beta', environment_key: 'GEMINI_API_KEY' },
		ModelProviderInfo{ id: 'groq', name: 'Groq', description: 'Fast inference · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'https://api.groq.com/openai/v1', environment_key: 'GROQ_API_KEY' },
		ModelProviderInfo{ id: 'huggingface', name: 'Hugging Face', description: 'Inference Providers · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'https://router.huggingface.co/v1', environment_key: 'HF_TOKEN' },
		ModelProviderInfo{ id: 'hyperbolic', name: 'Hyperbolic', description: 'Open models · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'https://api.hyperbolic.xyz/v1', environment_key: 'HYPERBOLIC_API_KEY' },
		ModelProviderInfo{ id: 'llama-cpp', name: 'llama.cpp', description: 'Local llama-server · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'http://127.0.0.1:8080/v1', requires_api_key: false },
		ModelProviderInfo{ id: 'lmstudio', name: 'LM Studio', description: 'Local model server · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'http://127.0.0.1:1234/v1', requires_api_key: false },
		ModelProviderInfo{ id: 'localai', name: 'LocalAI', description: 'Local AI server · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'http://127.0.0.1:8080/v1', requires_api_key: false },
		ModelProviderInfo{ id: 'mistral', name: 'Mistral AI', description: 'Mistral models · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'https://api.mistral.ai/v1', environment_key: 'MISTRAL_API_KEY' },
		ModelProviderInfo{ id: 'moonshot', name: 'Moonshot AI', description: 'Kimi models · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'https://api.moonshot.ai/v1', environment_key: 'MOONSHOT_API_KEY' },
		ModelProviderInfo{ id: 'nebius', name: 'Nebius AI Studio', description: 'Open models · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'https://api.studio.nebius.com/v1', environment_key: 'NEBIUS_API_KEY' },
		ModelProviderInfo{ id: 'novita', name: 'Novita AI', description: 'Open models · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'https://api.novita.ai/v3/openai', environment_key: 'NOVITA_API_KEY' },
		ModelProviderInfo{ id: 'nvidia', name: 'NVIDIA NIM', description: 'NIM endpoints · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'https://integrate.api.nvidia.com/v1', environment_key: 'NVIDIA_API_KEY' },
		ModelProviderInfo{ id: 'ollama', name: 'Ollama', description: 'Local models · OpenAI-compatible API, no key required', protocol: 'openai-compatible', base_url: 'http://127.0.0.1:11434/v1', requires_api_key: false },
		ModelProviderInfo{ id: 'openai', name: 'OpenAI', description: 'GPT models · OpenAI Chat Completions', protocol: 'openai-compatible', base_url: 'https://api.openai.com/v1', environment_key: 'OPENAI_API_KEY' },
		ModelProviderInfo{ id: 'openai-compatible', name: 'OpenAI-compatible', description: 'Custom endpoint · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'https://api.openai.com/v1', environment_key: 'OPENAI_API_KEY' },
		ModelProviderInfo{ id: 'openrouter', name: 'OpenRouter', description: 'Multi-provider routing · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'https://openrouter.ai/api/v1', environment_key: 'OPENROUTER_API_KEY' },
		ModelProviderInfo{ id: 'perplexity', name: 'Perplexity', description: 'Sonar models · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'https://api.perplexity.ai', environment_key: 'PERPLEXITY_API_KEY' },
		ModelProviderInfo{ id: 'sambanova', name: 'SambaNova', description: 'Fast inference · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'https://api.sambanova.ai/v1', environment_key: 'SAMBANOVA_API_KEY' },
		ModelProviderInfo{ id: 'siliconflow', name: 'SiliconFlow', description: 'Open models · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'https://api.siliconflow.com/v1', environment_key: 'SILICONFLOW_API_KEY' },
		ModelProviderInfo{ id: 'together', name: 'Together AI', description: 'Open models · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'https://api.together.xyz/v1', environment_key: 'TOGETHER_API_KEY' },
		ModelProviderInfo{ id: 'vercel', name: 'Vercel AI Gateway', description: 'Multi-provider gateway · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'https://ai-gateway.vercel.sh/v1', environment_key: 'AI_GATEWAY_API_KEY' },
		ModelProviderInfo{ id: 'venice', name: 'Venice AI', description: 'Open models · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'https://api.venice.ai/api/v1', environment_key: 'VENICE_API_KEY' },
		ModelProviderInfo{ id: 'vllm', name: 'vLLM', description: 'Self-hosted inference server · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'http://127.0.0.1:8000/v1', requires_api_key: false },
		ModelProviderInfo{ id: 'xai', name: 'xAI', description: 'Grok models · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'https://api.x.ai/v1', environment_key: 'XAI_API_KEY' },
		ModelProviderInfo{ id: 'zai', name: 'Z.AI', description: 'GLM models · OpenAI-compatible Chat Completions', protocol: 'openai-compatible', base_url: 'https://api.z.ai/api/paas/v4', environment_key: 'ZAI_API_KEY' },
	]
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
	active_provider string
	profiles        map[string]ModelProfileView
	providers       []ModelProviderInfo
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
	return ModelSettingsView{
		active_provider: state.settings.active_provider
		profiles:        profiles
		providers:       model_provider_catalog()
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
	mut state := app.model_settings
	state.mu.lock()
	profile := state.settings.profiles[provider] or { ModelProfile{} }
	state.mu.unlock()
	model := if profile.model.len > 0 { profile.model } else { fallback_model }
	api_key := provider_api_key(provider) or { profile.api_key }
	base_url := if profile.base_url.len > 0 {
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
