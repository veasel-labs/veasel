module main

import json2
import net.http
import net.urllib
import os
import strconv
import time

const max_chat_messages = 64
const max_chat_input_bytes = 100_000
const max_model_output_tokens = 4096
const max_provider_response_bytes = 1_000_000

pub struct ChatMessage {
pub:
	role    string
	content string
}

pub struct CompletionInput {
pub:
	messages []ChatMessage
}

pub struct CompletionOutput {
pub:
	provider string
	model    string
	content  string
}

struct ModelConfig {
	provider string
	base_url string
	model    string
	api_key  string
}

interface ModelProvider {
	complete(config ModelConfig, messages []ChatMessage) !CompletionOutput
}

struct OpenAICompatibleProvider {}

struct AnthropicProvider {}

struct GeminiProvider {}

struct OpenAIRequest {
	model      string
	max_tokens int
	messages   []ChatMessage
}

struct OpenAIResponse {
	choices []OpenAIChoice
}

struct OpenAIChoice {
	message ChatMessage
}

struct NativeMessage {
	role    string
	content string
}

struct AnthropicRequest {
	model      string
	max_tokens int
	system     string @[omitempty]
	messages   []NativeMessage
}

struct AnthropicResponse {
	content []AnthropicContentBlock
}

struct AnthropicContentBlock {
	type string
	text string
}

struct GeminiRequest {
	system_instruction GeminiContent @[json: 'systemInstruction']
	contents           []GeminiContent
	generation_config  GeminiGenerationConfig @[json: 'generationConfig']
}

struct GeminiGenerationConfig {
	max_output_tokens int @[json: 'maxOutputTokens']
}

struct GeminiContent {
	role  string
	parts []GeminiPart
}

struct GeminiPart {
	text string
}

struct GeminiResponse {
	candidates []GeminiCandidate
}

struct GeminiCandidate {
	content GeminiContent
}

fn model_config() !ModelConfig {
	provider := os.getenv_opt('VEASEL_MODEL_PROVIDER') or { 'openai-compatible' }
	raw_model := os.getenv_opt('VEASEL_MODEL') or { return error('model is not configured') }
	model := raw_model.trim_space()
	if model.trim_space().len == 0 || model.len > 200 {
		return error('model configuration is invalid')
	}
	api_key := provider_api_key(provider) or {
		return error('model credentials are not configured for ${provider}')
	}
	if api_key.trim_space().len == 0 {
		return error('model credentials are not configured for ${provider}')
	}
	base_url := os.getenv_opt('VEASEL_MODEL_BASE_URL') or {
		match provider {
			'openai-compatible', 'openai' { 'https://api.openai.com/v1' }
			'anthropic' { 'https://api.anthropic.com/v1' }
			'gemini' { 'https://generativelanguage.googleapis.com/v1beta' }
			else { return error('unsupported model provider') }
		}
	}
	if provider !in ['openai-compatible', 'openai', 'anthropic', 'gemini'] {
		return error('unsupported model provider')
	}
	validated_base_url := secure_endpoint(base_url)!
	return ModelConfig{
		provider: provider
		base_url: validated_base_url
		model:    model
		api_key:  api_key
	}
}

fn provider_api_key(provider string) ?string {
	if shared_key := os.getenv_opt('VEASEL_MODEL_API_KEY') {
		return shared_key
	}
	key_name := match provider {
		'openai-compatible', 'openai' { 'OPENAI_API_KEY' }
		'anthropic' { 'ANTHROPIC_API_KEY' }
		'gemini' { 'GEMINI_API_KEY' }
		else { return none }
	}
	return os.getenv_opt(key_name)
}

fn secure_endpoint(base_url string) !string {
	base := base_url.trim_space().trim_right('/')
	parsed := urllib.parse(base) or { return error('model endpoint is invalid') }
	if base.contains('@') || base.contains(' ') || parsed.host == '' || parsed.raw_query != ''
		|| parsed.fragment != '' {
		return error('model endpoint is invalid')
	}
	if parsed.scheme != 'https' && !(parsed.scheme == 'http' && is_loopback_host(parsed.host)) {
		return error('model endpoint must use HTTPS or loopback HTTP')
	}
	return base
}

fn is_loopback_host(host string) bool {
	mut name := host.to_lower()
	if name.starts_with('[::1]') {
		return valid_optional_port(name['[::1]'.len..])
	}
	if name.count(':') > 0 {
		parts := name.split(':')
		if parts.len != 2 {
			return false
		}
		name = parts[0]
		return name in ['localhost', '127.0.0.1'] && valid_port(parts[1])
	}
	return name in ['localhost', '127.0.0.1']
}

fn is_loopback_origin(origin string) bool {
	parsed := urllib.parse(origin) or { return false }
	if parsed.scheme != 'http' || parsed.host == '' || parsed.raw_query != '' || parsed.fragment != '' {
		return false
	}
	return origin == 'http://${parsed.host}' && is_loopback_host(parsed.host)
}

fn valid_optional_port(suffix string) bool {
	if suffix == '' {
		return true
	}
	if !suffix.starts_with(':') {
		return false
	}
	return valid_port(suffix[1..])
}

fn valid_port(value string) bool {
	port := strconv.atoi(value) or { return false }
	return port > 0 && port <= 65535
}

fn validate_messages(messages []ChatMessage) ! {
	if messages.len == 0 || messages.len > max_chat_messages {
		return error('messages must contain 1 to ${max_chat_messages} entries')
	}
	mut total_bytes := 0
	for message in messages {
		if message.role !in ['system', 'user', 'assistant'] {
			return error('message role is invalid')
		}
		if message.content.trim_space().len == 0 {
			return error('message content must not be empty')
		}
		total_bytes += message.content.len
		if total_bytes > max_chat_input_bytes {
			return error('messages exceed the ${max_chat_input_bytes} byte limit')
		}
	}
	if messages[messages.len - 1].role != 'user' {
		return error('the last message must be from the user')
	}
}

fn complete(input CompletionInput) !CompletionOutput {
	validate_messages(input.messages)!
	config := model_config()!
	provider := match config.provider {
		'openai-compatible', 'openai' { ModelProvider(OpenAICompatibleProvider{}) }
		'anthropic' { ModelProvider(AnthropicProvider{}) }
		'gemini' { ModelProvider(GeminiProvider{}) }
		else { return error('unsupported model provider') }
	}
	return provider.complete(config, input.messages)
}

fn configured_model() ?string {
	config := model_config() or { return none }
	return config.model
}

fn (provider OpenAICompatibleProvider) complete(config ModelConfig, messages []ChatMessage) !CompletionOutput {
	url := '${secure_endpoint(config.base_url)!}/chat/completions'
	request := OpenAIRequest{
		model:      config.model
		max_tokens: max_model_output_tokens
		messages:   messages
	}
	response := post_model_json(url, config, json2.encode[OpenAIRequest](request), .bearer)!
	decoded := json2.decode[OpenAIResponse](response.body) or {
		return error('response_parse')
	}
	if decoded.choices.len == 0 || decoded.choices[0].message.content.trim_space().len == 0 {
		return error('empty_response')
	}
	return CompletionOutput{
		provider: config.provider
		model:    config.model
		content:  decoded.choices[0].message.content
	}
}

fn (provider AnthropicProvider) complete(config ModelConfig, messages []ChatMessage) !CompletionOutput {
	base := secure_endpoint(config.base_url)!
	system, conversation := split_system_messages(messages)
	request := AnthropicRequest{
		model:      config.model
		max_tokens: max_model_output_tokens
		system:     system
		messages:   conversation
	}
	response := post_model_json('${base}/messages', config, json2.encode[AnthropicRequest](request), .anthropic)!
	decoded := json2.decode[AnthropicResponse](response.body) or {
		return error('response_parse')
	}
	mut content := []string{}
	for block in decoded.content {
		if block.type == 'text' && block.text != '' {
			content << block.text
		}
	}
	if content.len == 0 {
		return error('empty_response')
	}
	return CompletionOutput{
		provider: config.provider
		model:    config.model
		content:  content.join('')
	}
}

fn (provider GeminiProvider) complete(config ModelConfig, messages []ChatMessage) !CompletionOutput {
	base := secure_endpoint(config.base_url)!
	system, conversation := gemini_messages(messages)
	request := GeminiRequest{
		system_instruction: GeminiContent{
			parts: [GeminiPart{ text: system }]
		}
		contents:           conversation
		generation_config:  GeminiGenerationConfig{
			max_output_tokens: max_model_output_tokens
		}
	}
	model_path := urllib.path_escape(config.model)
	url := '${base}/models/${model_path}:generateContent'
	response := post_model_json(url, config, json2.encode[GeminiRequest](request), .gemini)!
	decoded := json2.decode[GeminiResponse](response.body) or {
		return error('response_parse')
	}
	if decoded.candidates.len == 0 {
		return error('empty_response')
	}
	mut content := []string{}
	for part in decoded.candidates[0].content.parts {
		if part.text != '' {
			content << part.text
		}
	}
	if content.len == 0 {
		return error('empty_response')
	}
	return CompletionOutput{
		provider: config.provider
		model:    config.model
		content:  content.join('')
	}
}

fn split_system_messages(messages []ChatMessage) (string, []NativeMessage) {
	mut system := []string{}
	mut conversation := []NativeMessage{cap: messages.len}
	for message in messages {
		if message.role == 'system' {
			system << message.content
		} else {
			conversation << NativeMessage{
				role:    message.role
				content: message.content
			}
		}
	}
	return system.join('\n\n'), conversation
}

fn gemini_messages(messages []ChatMessage) (string, []GeminiContent) {
	mut system := []string{}
	mut conversation := []GeminiContent{cap: messages.len}
	for message in messages {
		if message.role == 'system' {
			system << message.content
		} else {
			conversation << GeminiContent{
				role:  if message.role == 'assistant' { 'model' } else { 'user' }
				parts: [GeminiPart{ text: message.content }]
			}
		}
	}
	return if system.len > 0 {
		system.join('\n\n')
	} else {
		'You are Veasel Code, an AI coding assistant.'
	}, conversation
}

enum ModelAuth {
	bearer
	anthropic
	gemini
}

fn post_model_json(url string, config ModelConfig, payload string, auth ModelAuth) !http.Response {
	mut headers := http.new_header(key: .content_type, value: 'application/json')
	match auth {
		.bearer {
			headers.add_custom('Authorization', 'Bearer ${config.api_key}')!
		}
		.anthropic {
			headers.add_custom('x-api-key', config.api_key)!
			headers.add_custom('anthropic-version', '2023-06-01')!
		}
		.gemini {
			headers.add_custom('x-goog-api-key', config.api_key)!
		}
	}
	response := http.fetch(
		method:               .post
		url:                  url
		header:               headers
		data:                 payload
		read_timeout:         60 * time.second
		write_timeout:        10 * time.second
		allow_redirect:       false
		max_retries:          1
		stop_receiving_limit: max_provider_response_bytes
		validate:             true
	) or { return error('transport') }
	if response.status_code < 200 || response.status_code >= 300 {
		return error('HTTP ${response.status_code}')
	}
	return response
}
