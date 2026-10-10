module main

import json2
import context as vcontext
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
	role                  string
	content               string
	name                  string             @[omitempty]
	tool_call_id          string             @[json: 'tool_call_id'; omitempty]
	provider_tool_call_id string             @[json: 'provider_tool_call_id'; omitempty]
	tool_calls            []ProviderToolCall @[json: 'tool_calls'; omitempty]
}

pub struct CompletionInput {
pub:
	messages []ChatMessage
}

pub struct CompletionOutput {
	tool_calls []ProviderToolCall
pub:
	provider string
	model    string
	content  string
}

pub struct ProviderToolCall {
pub:
	id                 string
	provider_call_id   string @[json: 'provider_call_id'; omitempty]
	type               string = 'function'
	function           ProviderFunctionCall
	provider_signature string @[json: 'provider_signature'; omitempty]
}

pub struct ProviderFunctionCall {
pub:
	name      string
	arguments string
}

pub struct AgentToolDefinition {
pub:
	name        string
	description string
	parameters  ToolParameters
	// MCP input schemas stay raw so nested JSON Schema types pass through intact.
	raw_parameters string
}

pub struct ToolParameters {
pub:
	type       string = 'object'
	properties map[string]ToolParameter
	required   []string
}

struct StrictToolParameters {
	type                  string = 'object'
	properties            map[string]ToolParameter
	required              []string
	additional_properties bool @[json: 'additionalProperties']
}

pub struct ToolParameter {
pub:
	type        string
	description string @[omitempty]
}

struct ModelConfig {
	provider string
	base_url string
	model    string
	api_key  string
}

interface ModelProvider {
	complete(mut turn_ctx vcontext.Context, config ModelConfig, messages []ChatMessage,
		tools []AgentToolDefinition) !CompletionOutput
}

struct ProviderTurnResult {
	output CompletionOutput
	error  string
}

struct OpenAICompatibleProvider {}

struct AnthropicProvider {}

struct GeminiProvider {}

struct OpenAIRequest {
	model       string
	max_tokens  int
	messages    []ChatMessage
	tools       []OpenAITool @[omitempty]
	tool_choice string       @[omitempty]
}

struct OpenAITool {
	type     string = 'function'
	function OpenAIFunction
}

struct OpenAIFunction {
	name        string
	description string
	parameters  json2.Any
}

struct OpenAIResponse {
	choices []OpenAIChoice
}

struct OpenAIChoice {
	message       OpenAIResponseMessage
	finish_reason string
}

struct OpenAIResponseMessage {
	role       string
	content    ?string
	tool_calls []ProviderToolCall @[json: 'tool_calls'; omitempty]
}

struct AnthropicRequest {
	model      string
	max_tokens int
	system     string @[omitempty]
	messages   []AnthropicRequestMessage
	tools      []AnthropicTool @[omitempty]
}

struct AnthropicRequestMessage {
	role    string
	content []AnthropicContentBlock
}

struct AnthropicTool {
	name         string
	description  string
	input_schema json2.Any
}

struct AnthropicResponse {
	content []AnthropicContentBlock
}

struct AnthropicContentBlock {
	type        string
	text        string               @[omitempty]
	content     string               @[omitempty]
	id          string               @[omitempty]
	name        string               @[omitempty]
	input       map[string]json2.Any @[omitempty]
	tool_use_id string               @[json: 'tool_use_id'; omitempty]
}

struct GeminiRequest {
	system_instruction GeminiContent @[json: 'systemInstruction']
	contents           []GeminiContent
	generation_config  GeminiGenerationConfig @[json: 'generationConfig']
	tools              []GeminiToolGroup      @[omitempty]
}

struct GeminiToolGroup {
	function_declarations []GeminiFunctionDeclaration @[json: 'functionDeclarations']
}

struct GeminiFunctionDeclaration {
	name        string
	description string
	parameters  json2.Any
}

struct GeminiGenerationConfig {
	max_output_tokens int @[json: 'maxOutputTokens']
}

struct GeminiContent {
	role  string
	parts []GeminiPart
}

struct GeminiPart {
	text              string                  @[omitempty]
	function_call     ?GeminiFunctionCall     @[json: 'functionCall'; omitempty]
	function_response ?GeminiFunctionResponse @[json: 'functionResponse'; omitempty]
	thought_signature string                  @[json: 'thoughtSignature'; omitempty]
}

struct GeminiFunctionCall {
	id   string @[omitempty]
	name string
	args map[string]json2.Any
}

struct GeminiFunctionResponse {
	id       string @[omitempty]
	name     string
	response map[string]json2.Any
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
		if message.name != '' || message.tool_call_id != '' || message.provider_tool_call_id != ''
			|| message.tool_calls.len > 0 {
			return error('provider tool metadata is not accepted in completion input')
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

fn complete_with_turn_context(mut turn_ctx vcontext.Context, messages []ChatMessage,
	tools []AgentToolDefinition) ProviderTurnResult {
	output := complete_with_tools(mut turn_ctx, messages, tools) or {
		return ProviderTurnResult{
			error: err.msg()
		}
	}
	return ProviderTurnResult{
		output: output
	}
}

fn complete_with_tools(mut turn_ctx vcontext.Context, messages []ChatMessage,
	tools []AgentToolDefinition) !CompletionOutput {
	config := model_config()!
	provider := match config.provider {
		'openai-compatible', 'openai' { ModelProvider(OpenAICompatibleProvider{}) }
		'anthropic' { ModelProvider(AnthropicProvider{}) }
		'gemini' { ModelProvider(GeminiProvider{}) }
		else { return error('unsupported model provider') }
	}
	return provider.complete(mut turn_ctx, config, messages, tools)
}

fn configured_model() ?string {
	config := model_config() or { return none }
	return config.model
}

fn (provider OpenAICompatibleProvider) complete(mut turn_ctx vcontext.Context, config ModelConfig,
	messages []ChatMessage,
	tools []AgentToolDefinition) !CompletionOutput {
	url := '${secure_endpoint(config.base_url)!}/chat/completions'
	mut openai_tools := []OpenAITool{cap: tools.len}
	for tool in tools {
		openai_tools << OpenAITool{
			function: OpenAIFunction{
				name:        tool.name
				description: tool.description
				parameters:  provider_tool_parameters(tool)
			}
		}
	}
	request := OpenAIRequest{
		model:       config.model
		max_tokens:  max_model_output_tokens
		messages:    messages
		tools:       openai_tools
		tool_choice: if tools.len > 0 { 'auto' } else { '' }
	}
	response := post_model_json(mut turn_ctx, url, config, json2.encode[OpenAIRequest](request), .bearer)!
	decoded := json2.decode[OpenAIResponse](response.body) or {
		return error('response_parse')
	}
	if decoded.choices.len == 0 {
		return error('empty_response')
	}
	message := decoded.choices[0].message
	content := message.content or { '' }
	if content.trim_space().len == 0 && message.tool_calls.len == 0 {
		return error('empty_response')
	}
	return CompletionOutput{
		provider:   config.provider
		model:      config.model
		content:    content
		tool_calls: message.tool_calls
	}
}

fn (provider AnthropicProvider) complete(mut turn_ctx vcontext.Context, config ModelConfig,
	messages []ChatMessage,
	tools []AgentToolDefinition) !CompletionOutput {
	base := secure_endpoint(config.base_url)!
	system, conversation := anthropic_messages(messages)
	mut anthropic_tools := []AnthropicTool{cap: tools.len}
	for tool in tools {
		anthropic_tools << AnthropicTool{
			name:         tool.name
			description:  tool.description
			input_schema: provider_tool_parameters(tool)
		}
	}
	request := AnthropicRequest{
		model:      config.model
		max_tokens: max_model_output_tokens
		system:     system
		messages:   conversation
		tools:      anthropic_tools
	}
	response := post_model_json(mut turn_ctx, '${base}/messages', config,
		json2.encode[AnthropicRequest](request), .anthropic)!
	decoded := json2.decode[AnthropicResponse](response.body) or {
		return error('response_parse')
	}
	mut content := []string{}
	mut tool_calls := []ProviderToolCall{}
	for block in decoded.content {
		if block.type == 'text' && block.text != '' {
			content << block.text
		} else if block.type == 'tool_use' && block.id != '' && block.name != '' {
			tool_calls << ProviderToolCall{
				id:               block.id
				provider_call_id: block.id
				type:             'function'
				function:         ProviderFunctionCall{
					name:      block.name
					arguments: json2.encode[map[string]json2.Any](block.input)
				}
			}
		}
	}
	if content.len == 0 && tool_calls.len == 0 {
		return error('empty_response')
	}
	return CompletionOutput{
		provider:   config.provider
		model:      config.model
		content:    content.join('')
		tool_calls: tool_calls
	}
}

fn (provider GeminiProvider) complete(mut turn_ctx vcontext.Context, config ModelConfig,
	messages []ChatMessage,
	tools []AgentToolDefinition) !CompletionOutput {
	base := secure_endpoint(config.base_url)!
	system, conversation := gemini_messages(messages)
	mut declarations := []GeminiFunctionDeclaration{cap: tools.len}
	for tool in tools {
		declarations << GeminiFunctionDeclaration{
			name:        tool.name
			description: tool.description
			parameters:  tool_parameters_json(tool)
		}
	}
	request := GeminiRequest{
		system_instruction: GeminiContent{
			parts: [GeminiPart{ text: system }]
		}
		contents:           conversation
		generation_config:  GeminiGenerationConfig{
			max_output_tokens: max_model_output_tokens
		}
		tools:              if declarations.len > 0 {
			[GeminiToolGroup{
				function_declarations: declarations
			}]
		} else {
			[]
		}
	}
	model_path := urllib.path_escape(config.model)
	url := '${base}/models/${model_path}:generateContent'
	response := post_model_json(mut turn_ctx, url, config, json2.encode[GeminiRequest](request), .gemini)!
	decoded := json2.decode[GeminiResponse](response.body) or {
		return error('response_parse')
	}
	if decoded.candidates.len == 0 {
		return error('empty_response')
	}
	mut content := []string{}
	mut tool_calls := []ProviderToolCall{}
	for part in decoded.candidates[0].content.parts {
		if part.text != '' {
			content << part.text
		}
		if function_call := part.function_call {
			tool_calls << ProviderToolCall{
				id:                 if function_call.id != '' {
					function_call.id
				} else {
					'gemini-${messages.len}-${tool_calls.len + 1}'
				}
				provider_call_id:   function_call.id
				provider_signature: part.thought_signature
				type:               'function'
				function:           ProviderFunctionCall{
					name:      function_call.name
					arguments: json2.encode[map[string]json2.Any](function_call.args)
				}
			}
		}
	}
	if content.len == 0 && tool_calls.len == 0 {
		return error('empty_response')
	}
	return CompletionOutput{
		provider:   config.provider
		model:      config.model
		content:    content.join('')
		tool_calls: tool_calls
	}
}

fn anthropic_messages(messages []ChatMessage) (string, []AnthropicRequestMessage) {
	mut system := []string{}
	mut conversation := []AnthropicRequestMessage{cap: messages.len}
	mut pending_tool_results := []AnthropicContentBlock{}
	for message in messages {
		if message.role == 'system' {
			system << message.content
			continue
		}
		if message.role == 'tool' {
			pending_tool_results << AnthropicContentBlock{
				type:        'tool_result'
				tool_use_id: message.tool_call_id
				content:     message.content
			}
			continue
		}
		if pending_tool_results.len > 0 {
			conversation << AnthropicRequestMessage{
				role:    'user'
				content: pending_tool_results
			}
			pending_tool_results = []
		}
		mut blocks := []AnthropicContentBlock{}
		if message.content != '' {
			blocks << AnthropicContentBlock{
				type: 'text'
				text: message.content
			}
		}
		for call in message.tool_calls {
			tool_arguments := json2.decode[map[string]json2.Any](call.function.arguments) or {
				map[string]json2.Any{}
			}
			blocks << AnthropicContentBlock{
				type:  'tool_use'
				id:    call.id
				name:  call.function.name
				input: tool_arguments
			}
		}
		conversation << AnthropicRequestMessage{
			role:    message.role
			content: blocks
		}
	}
	if pending_tool_results.len > 0 {
		conversation << AnthropicRequestMessage{
			role:    'user'
			content: pending_tool_results
		}
	}
	return system.join('\n\n'), conversation
}

fn strict_tool_parameters(parameters ToolParameters) StrictToolParameters {
	return StrictToolParameters{
		properties:            parameters.properties
		required:              parameters.required
		additional_properties: false
	}
}

fn tool_parameters_json(tool AgentToolDefinition) json2.Any {
	if tool.raw_parameters != '' {
		return json2.decode[json2.Any](tool.raw_parameters) or { json2.Any{} }
	}
	return json2.decode[json2.Any](json2.encode[ToolParameters](tool.parameters)) or { json2.Any{} }
}

fn provider_tool_parameters(tool AgentToolDefinition) json2.Any {
	if tool.raw_parameters != '' {
		return json2.decode[json2.Any](tool.raw_parameters) or { json2.Any{} }
	}
	return json2.decode[json2.Any](json2.encode[StrictToolParameters](strict_tool_parameters(tool.parameters))) or {
		json2.Any{}
	}
}

fn gemini_messages(messages []ChatMessage) (string, []GeminiContent) {
	mut system := []string{}
	mut conversation := []GeminiContent{cap: messages.len}
	mut pending_tool_results := []GeminiPart{}
	for message in messages {
		if message.role == 'system' {
			system << message.content
		} else if message.role == 'tool' {
			response := json2.decode[map[string]json2.Any](message.content) or {
				{
					'content': json2.Any(message.content)
				}
			}
			pending_tool_results << GeminiPart{
				function_response: GeminiFunctionResponse{
					id:       message.provider_tool_call_id
					name:     message.name
					response: response
				}
			}
		} else {
			if pending_tool_results.len > 0 {
				conversation << GeminiContent{
					role:  'user'
					parts: pending_tool_results
				}
				pending_tool_results = []
			}
			mut parts := []GeminiPart{}
			if message.content != '' {
				parts << GeminiPart{
					text: message.content
				}
			}
			for call in message.tool_calls {
				tool_arguments := json2.decode[map[string]json2.Any](call.function.arguments) or {
					map[string]json2.Any{}
				}
				parts << GeminiPart{
					function_call:     GeminiFunctionCall{
						id:   call.provider_call_id
						name: call.function.name
						args: tool_arguments
					}
					thought_signature: call.provider_signature
				}
			}
			if parts.len == 0 {
				continue
			}
			conversation << GeminiContent{
				role:  if message.role == 'assistant' { 'model' } else { 'user' }
				parts: parts
			}
		}
	}
	if pending_tool_results.len > 0 {
		conversation << GeminiContent{
			role:  'user'
			parts: pending_tool_results
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

fn post_model_json(mut turn_ctx vcontext.Context, url string, config ModelConfig, payload string,
	auth ModelAuth) !http.Response {
	if context_error := turn_context_error(mut turn_ctx) {
		return error(context_error)
	}
	deadline := turn_ctx.deadline() or { return error('deadline_missing') }
	remaining := deadline - time.now()
	if remaining <= 0 {
		return error('deadline_exceeded')
	}
	read_timeout := if remaining < 60 * time.second { remaining } else { 60 * time.second }
	write_timeout := if remaining < 10 * time.second { remaining } else { 10 * time.second }
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
		read_timeout:         read_timeout
		write_timeout:        write_timeout
		allow_redirect:       false
		max_retries:          1
		stop_receiving_limit: max_provider_response_bytes
		validate:             true
		on_progress:          fn [turn_ctx] (request &http.Request, chunk []u8, read_so_far u64) ! {
			mut active_ctx := turn_ctx
			if context_error := turn_context_error(mut active_ctx) {
				return error(context_error)
			}
		}
	) or { return error('transport') }
	if response.status_code < 200 || response.status_code >= 300 {
		return error('HTTP ${response.status_code}')
	}
	return response
}
