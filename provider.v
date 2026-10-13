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
const max_provider_stream_bytes = 16_000_000
const max_provider_model_catalog_bytes = 1_000_000
const max_provider_model_catalog_entries = 500

pub struct ChatMessage {
pub:
	role                  string
	content               string
	name                  string             @[omitempty]
	tool_call_id          string             @[json: 'tool_call_id'; omitempty]
	provider_tool_call_id string             @[json: 'provider_tool_call_id'; omitempty]
	tool_calls            []ProviderToolCall @[json: 'tool_calls'; omitempty]
	provider_context      []string           @[json: '-']
}

pub struct CompletionInput {
pub:
	messages []ChatMessage
}

pub struct CompletionOutput {
	tool_calls []ProviderToolCall
pub:
	provider         string
	model            string
	content          string
	provider_context []string @[json: '-']
}

pub struct ModelCatalogEntry {
pub:
	id   string
	name string
}

struct OpenAIModelCatalog {
	data []OpenAIModelCatalogEntry
}

struct OpenAIModelCatalogEntry {
	id   string
	name string
}

struct AnthropicModelCatalog {
	data []AnthropicModelCatalogEntry
}

struct AnthropicModelCatalogEntry {
	id           string
	display_name string @[json: 'display_name']
}

struct GeminiModelCatalog {
	models []GeminiModelCatalogEntry
}

struct GeminiModelCatalogEntry {
	name                         string
	display_name                 string   @[json: 'displayName']
	supported_generation_methods []string @[json: 'supportedGenerationMethods']
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

type ProviderTextDeltaFn = fn (delta string) !
type ProviderSSEDataFn = fn (data string) !

struct ProviderSSEDecoder {
mut:
	on_data ProviderSSEDataFn @[required]
	pending string
}

struct ProviderSSERequestState {
mut:
	decoder ProviderSSEDecoder
	bytes   int
}

fn (mut decoder ProviderSSEDecoder) feed(chunk string) ! {
	decoder.pending += chunk
	trailing_cr := decoder.pending.ends_with('\r')
	if trailing_cr {
		prefix := decoder.pending[..decoder.pending.len - 1]
		decoder.pending = prefix.replace('\r\n', '\n').replace('\r', '\n') + '\r'
	} else {
		decoder.pending = decoder.pending.replace('\r\n', '\n').replace('\r', '\n')
	}
	for {
		lf_end := decoder.pending.index('\n\n') or { -1 }
		if lf_end < 0 {
			if decoder.pending.len > max_provider_response_bytes {
				return error('stream frame size limit exceeded')
			}
			break
		}
		if lf_end > max_provider_response_bytes {
			return error('stream frame size limit exceeded')
		}
		block := decoder.pending[..lf_end]
		decoder.pending = decoder.pending[lf_end + 2..]
		mut lines := []string{}
		for line in block.split('\n') {
			if line.starts_with('data:') {
				value := line[5..]
				lines << if value.starts_with(' ') { value[1..] } else { value }
			}
		}
		if lines.len > 0 {
			decoder.on_data(lines.join('\n'))!
		}
	}
}

fn (mut decoder ProviderSSEDecoder) finish() ! {
	if decoder.pending.len > 0 {
		decoder.pending += '\n\n'
		decoder.feed('')!
	}
}

struct ModelConfig {
	provider string
	base_url string
	model    string
	api_key  string
}

fn fetch_provider_models(config ModelConfig) ![]ModelCatalogEntry {
	info := model_provider_info(config.provider) or { return error('unsupported model provider') }
	url := '${secure_endpoint(config.base_url)!}/models'
	verify := provider_tls_verify_path(url)!
	mut headers := http.new_header(key: .accept, value: 'application/json')
	match info.protocol {
		'openai-compatible', 'openai-responses' {
			if config.api_key.len > 0 {
				headers.add_custom('Authorization', 'Bearer ${config.api_key}')!
			}
		}
		'anthropic' {
			headers.add_custom('x-api-key', config.api_key)!
			headers.add_custom('anthropic-version', '2023-06-01')!
		}
		'gemini' {
			headers.add_custom('x-goog-api-key', config.api_key)!
		}
		else { return error('unsupported model provider') }
	}
	response := http.fetch(
		method:               .get
		url:                  url
		header:               headers
		read_timeout:         5 * time.second
		write_timeout:        2 * time.second
		max_retries:          1
		allow_redirect:       false
		stop_receiving_limit: max_provider_model_catalog_bytes
		validate:             true
		verify:               verify
	) or { return error('model catalog request failed') }
	if response.status_code < 200 || response.status_code >= 300 {
		return error('model catalog endpoint returned HTTP ${response.status_code}')
	}
	if response.body.len > max_provider_model_catalog_bytes {
		return error('model catalog response is too large')
	}
	models := parse_provider_model_catalog(info.protocol, response.body)!
	return filter_provider_chat_models(config.provider, models)
}

fn filter_provider_chat_models(provider string, models []ModelCatalogEntry) []ModelCatalogEntry {
	if provider != 'meta' {
		return models
	}
	mut compatible := []ModelCatalogEntry{cap: models.len}
	for model in models {
		id := model.id.to_lower()
		if id.starts_with('muse-wonder-') || id.starts_with('muse-spark-') {
			compatible << model
		}
	}
	return compatible
}

fn parse_provider_model_catalog(protocol string, body string) ![]ModelCatalogEntry {
	mut models := []ModelCatalogEntry{}
	match protocol {
		'openai-compatible', 'openai-responses' {
			catalog := json2.decode[OpenAIModelCatalog](body) or {
				return error('model catalog response is invalid')
			}
			for item in catalog.data {
				append_model_catalog_entry(mut models, item.id, item.name)
			}
		}
		'anthropic' {
			catalog := json2.decode[AnthropicModelCatalog](body) or {
				return error('model catalog response is invalid')
			}
			for item in catalog.data {
				append_model_catalog_entry(mut models, item.id, item.display_name)
			}
		}
		'gemini' {
			catalog := json2.decode[GeminiModelCatalog](body) or {
				return error('model catalog response is invalid')
			}
			for item in catalog.models {
				if 'generateContent' !in item.supported_generation_methods {
					continue
				}
				id := if item.name.starts_with('models/') {
					item.name['models/'.len..]
				} else {
					item.name
				}
				append_model_catalog_entry(mut models, id, item.display_name)
			}
		}
		else { return error('unsupported model protocol') }
	}
	if models.len > max_provider_model_catalog_entries {
		models = models[..max_provider_model_catalog_entries]
	}
	return models
}

fn append_model_catalog_entry(mut models []ModelCatalogEntry, id string, name string) {
	clean_id := id.trim_space()
	if clean_id.len == 0 || clean_id.len > 200 || models.len >= max_provider_model_catalog_entries {
		return
	}
	for existing in models {
		if existing.id == clean_id {
			return
		}
	}
	models << ModelCatalogEntry{
		id:   clean_id
		name: if name.trim_space().len > 0 { name.trim_space() } else { clean_id }
	}
}

interface ModelProvider {
	complete(mut turn_ctx vcontext.Context, config ModelConfig, messages []ChatMessage,
		tools []AgentToolDefinition, on_text_delta ProviderTextDeltaFn) !CompletionOutput
}

struct ProviderTurnResult {
	output CompletionOutput
	error  string
}

struct OpenAICompatibleProvider {}

struct OpenAIResponsesProvider {}

struct AnthropicProvider {}

struct GeminiProvider {}

struct OpenAIRequest {
	model       string
	max_tokens  int
	messages    []ChatMessage
	tools       []OpenAITool @[omitempty]
	tool_choice string       @[omitempty]
	stream      bool
}

struct OpenAIResponsesRequest {
	model               string
	max_output_tokens   int
	input               []json2.Any
	tools               []OpenAIResponsesTool @[omitempty]
	tool_choice         string                @[omitempty]
	parallel_tool_calls bool                  @[omitempty]
	stream              bool
	store               bool
	include             []string                  @[omitempty]
	reasoning           ?OpenAIResponsesReasoning @[omitempty]
}

struct OpenAIResponsesReasoning {
	effort  string
	summary string @[omitempty]
}

struct OpenAIResponsesTool {
	type        string = 'function'
	name        string
	description string @[omitempty]
	parameters  json2.Any
}

struct OpenAIResponsesEvent {
	type     string
	delta    string
	response OpenAIResponsesResponse
	error    OpenAIResponsesError
}

struct OpenAIResponsesError {
	message string
}

struct OpenAIResponsesResponse {
	id          string
	model       string
	status      string
	output_text string
	output      []OpenAIResponsesOutputItem
	error       OpenAIResponsesError
}

struct OpenAIResponsesOutputItem {
	id                string
	type              string
	call_id           string
	name              string
	arguments         string
	role              string
	phase             string
	content           []OpenAIResponsesOutputContent
	summary           []json2.Any
	encrypted_content string
}

struct OpenAIResponsesOutputContent {
	type string
	text string
}

struct OpenAIResponsesStreamOutput {
mut:
	content_parts []string
	response      OpenAIResponsesResponse
	failure       string
	completed     bool
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

struct OpenAIStreamChunk {
	choices []OpenAIStreamChoice
}

struct OpenAIStreamChoice {
	delta OpenAIStreamDelta
}

struct OpenAIStreamDelta {
	content    ?string
	tool_calls []OpenAIStreamToolCallDelta @[json: 'tool_calls'; omitempty]
}

struct OpenAIStreamToolCallDelta {
	index    int
	id       string
	type     string
	function OpenAIStreamFunctionDelta
}

struct OpenAIStreamToolCall {
mut:
	id        string
	type      string
	name      string
	arguments string
}

struct OpenAIStreamOutput {
mut:
	content_parts []string
	tools         []OpenAIStreamToolCall
}

struct OpenAIStreamFunctionDelta {
	name      string
	arguments string
}

struct AnthropicRequest {
	model      string
	max_tokens int
	system     string @[omitempty]
	messages   []AnthropicRequestMessage
	tools      []AnthropicTool @[omitempty]
	stream     bool
}

struct AnthropicStreamEvent {
	type          string
	index         int
	content_block AnthropicContentBlock
	delta         AnthropicStreamDelta
}

struct AnthropicStreamDelta {
	type         string
	text         string
	partial_json string
}

struct AnthropicStreamToolCall {
mut:
	id        string
	name      string
	arguments string
}

struct AnthropicStreamOutput {
mut:
	content_parts []string
	tools         []AnthropicStreamToolCall
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

struct GeminiStreamOutput {
mut:
	content []string
	tools   []ProviderToolCall
}

struct GeminiCandidate {
	content GeminiContent
}

fn provider_api_key(provider string) ?string {
	if shared_key := non_empty_environment_value('VEASEL_MODEL_API_KEY') {
		return shared_key
	}
	info := model_provider_info(provider) or { return none }
	if info.environment_key == '' { return none }
	return non_empty_environment_value(info.environment_key)
}

fn provider_tls_verify_path(url string) !string {
	parsed := urllib.parse(url) or { return error('model endpoint is invalid') }
	if parsed.scheme.to_lower() != 'https' {
		return ''
	}
	$if windows {
		// V's HTTP backend uses Windows Schannel and the OS certificate store.
		return ''
	}
	if configured := os.getenv_opt('SSL_CERT_FILE') {
		if os.is_file(configured) {
			return configured
		}
		return error('SSL_CERT_FILE does not point to a readable CA bundle')
	}
	for candidate in [
		'/etc/ssl/certs/ca-certificates.crt',
		'/etc/ssl/cert.pem',
		'/etc/pki/tls/certs/ca-bundle.crt',
		'/etc/ssl/ca-bundle.pem',
		'/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem',
		'/usr/local/share/certs/ca-root-nss.crt',
		'/usr/local/etc/ca-certificates/cert.pem',
		'/opt/homebrew/etc/ca-certificates/cert.pem',
		'/usr/local/etc/openssl@3/cert.pem',
		'/opt/homebrew/etc/openssl@3/cert.pem',
	] {
		if os.is_file(candidate) {
			return candidate
		}
	}
	return error('system CA bundle not found; install ca-certificates or set SSL_CERT_FILE')
}

fn non_empty_environment_value(name string) ?string {
	value := os.getenv_opt(name) or { return none }
	if value.trim_space().len == 0 {
		return none
	}
	return value
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
	tools []AgentToolDefinition, on_text_delta ProviderTextDeltaFn, config ModelConfig) ProviderTurnResult {
	output := complete_with_tools(mut turn_ctx, messages, tools, on_text_delta, config) or {
		return ProviderTurnResult{
			error: err.msg()
		}
	}
	return ProviderTurnResult{
		output: output
	}
}

fn complete_with_tools(mut turn_ctx vcontext.Context, messages []ChatMessage,
	tools []AgentToolDefinition, on_text_delta ProviderTextDeltaFn, config ModelConfig) !CompletionOutput {
	info := model_provider_info(config.provider) or { return error('unsupported model provider') }
	provider := match info.protocol {
		'openai-compatible' {
			ModelProvider(OpenAICompatibleProvider{})
		}
		'openai-responses' {
			ModelProvider(OpenAIResponsesProvider{})
		}
		'anthropic' {
			ModelProvider(AnthropicProvider{})
		}
		'gemini' {
			ModelProvider(GeminiProvider{})
		}
		else { return error('unsupported model provider') }
	}
	return provider.complete(mut turn_ctx, config, messages, tools, on_text_delta)
}

fn ignore_provider_text_delta(_ string) ! {}

fn (provider OpenAICompatibleProvider) complete(mut turn_ctx vcontext.Context, config ModelConfig,
	messages []ChatMessage,
	tools []AgentToolDefinition, on_text_delta ProviderTextDeltaFn) !CompletionOutput {
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
		stream:      true
	}
	mut stream_state := &OpenAIStreamOutput{}
	callback := fn [mut stream_state, on_text_delta] (data string) ! {
		if data == '[DONE]' {
			return
		}
		chunk := json2.decode[OpenAIStreamChunk](data) or { return error('response_parse') }
		for choice in chunk.choices {
			if text := choice.delta.content {
				if text != '' {
					stream_state.content_parts << text
					on_text_delta(text)!
				}
			}
			for tool_delta in choice.delta.tool_calls {
				if tool_delta.index < 0 || tool_delta.index > 128 {
					return error('invalid streamed tool index')
				}
				for stream_state.tools.len <= tool_delta.index {
					stream_state.tools << OpenAIStreamToolCall{}
				}
				mut tool := stream_state.tools[tool_delta.index]
				if tool_delta.id != '' { tool.id += tool_delta.id }
				if tool_delta.type != '' { tool.type = tool_delta.type }
				tool.name += tool_delta.function.name
				tool.arguments += tool_delta.function.arguments
				if tool.arguments.len > max_provider_response_bytes {
					return error('tool arguments size limit exceeded')
				}
				stream_state.tools[tool_delta.index] = tool
			}
		}
	}
	post_model_sse(mut turn_ctx, url, config, json2.encode[OpenAIRequest](request), .bearer,
		callback)!
	content := stream_state.content_parts.join('')
	mut tool_calls := []ProviderToolCall{}
	for tool in stream_state.tools {
		if tool.id == '' && tool.name == '' && tool.arguments == '' {
			continue
		}
		if tool.id == '' || tool.name == '' || tool.arguments == '' {
			return error('incomplete streamed tool call')
		}
		json2.decode[map[string]json2.Any](tool.arguments) or {
			return error('invalid streamed tool arguments')
		}
		tool_calls << ProviderToolCall{
			id:       tool.id
			type:     if tool.type == '' { 'function' } else { tool.type }
			function: ProviderFunctionCall{
				name:      tool.name
				arguments: tool.arguments
			}
		}
	}
	if content.trim_space().len == 0 && tool_calls.len == 0 {
		return error('empty_response')
	}
	return CompletionOutput{
		provider:   config.provider
		model:      config.model
		content:    content
		tool_calls: tool_calls
	}
}

fn (provider OpenAIResponsesProvider) complete(mut turn_ctx vcontext.Context, config ModelConfig,
	messages []ChatMessage, tools []AgentToolDefinition,
	on_text_delta ProviderTextDeltaFn) !CompletionOutput {
	input := openai_responses_input(messages)!
	mut response_tools := []OpenAIResponsesTool{cap: tools.len}
	for tool in tools {
		response_tools << OpenAIResponsesTool{
			name:        tool.name
			description: tool.description
			parameters:  provider_tool_parameters(tool)
		}
	}
	request := OpenAIResponsesRequest{
		model:               config.model
		max_output_tokens:   max_model_output_tokens
		input:               input
		tools:               response_tools
		tool_choice:         if tools.len > 0 { 'auto' } else { '' }
		parallel_tool_calls: tools.len > 1
		stream:              true
		store:               false
		include:             openai_responses_include(config.provider, config.model)
		reasoning:           openai_responses_reasoning(config.provider, config.model)
	}
	mut stream_state := &OpenAIResponsesStreamOutput{}
	callback := fn [mut stream_state, on_text_delta] (data string) ! {
		if data == '[DONE]' { return }
		event := json2.decode[OpenAIResponsesEvent](data) or {
			return error('response_parse')
		}
		match event.type {
			'response.output_text.delta' {
				if event.delta != '' {
					stream_state.content_parts << event.delta
					on_text_delta(event.delta)!
				}
			}
			'response.completed' {
				stream_state.response = event.response
				stream_state.completed = true
			}
			'response.failed', 'error' {
				stream_state.failure = openai_responses_failure_message(event)
			}
			else {}
		}
	}
	post_model_sse(mut turn_ctx, '${secure_endpoint(config.base_url)!}/responses', config,
		json2.encode[OpenAIResponsesRequest](request), .bearer, callback)!
	if stream_state.failure != '' { return error(stream_state.failure) }
	if !stream_state.completed { return error('provider response ended before completion') }
	mut content := stream_state.content_parts.join('')
	mut tool_calls := []ProviderToolCall{}
	mut provider_context := []string{}
	for item in stream_state.response.output {
		match item.type {
			'reasoning' {
				if item.encrypted_content != '' {
					mut context_item := map[string]json2.Any{
						'type':              json2.Any('reasoning')
						'summary':           json2.Any(item.summary)
						'encrypted_content': json2.Any(item.encrypted_content)
					}
					if item.id != '' { context_item['id'] = json2.Any(item.id) }
					provider_context << json2.encode[map[string]json2.Any](context_item)
				}
			}
			'function_call' {
				if item.call_id.len == 0 || item.call_id.len > 64 || item.name.len == 0
					|| item.arguments.len == 0 {
					return error('provider returned an invalid function call')
				}
				json2.decode[map[string]json2.Any](item.arguments) or {
					return error('invalid streamed tool arguments')
				}
				tool_calls << ProviderToolCall{
					id:               item.call_id
					provider_call_id: item.id
					function:         ProviderFunctionCall{
						name:      item.name
						arguments: item.arguments
					}
				}
			}
			'message' {
				if content.len == 0 {
					for part in item.content {
						if part.type == 'output_text' { content += part.text }
					}
				}
			}
			else {}
		}
	}
	if content.trim_space().len == 0 && tool_calls.len == 0 {
		return error('empty_response')
	}
	return CompletionOutput{
		provider:         config.provider
		model:            if stream_state.response.model.len > 0 {
			stream_state.response.model
		} else {
			config.model
		}
		content:          content
		tool_calls:       tool_calls
		provider_context: provider_context
	}
}

fn openai_responses_model_supports_reasoning(provider string, model string) bool {
	if provider == 'meta' {
		return true
	}
	model_id := model.to_lower()
	return model_id.starts_with('gpt-5') || model_id.starts_with('o1') || model_id.starts_with('o3')
		|| model_id.starts_with('o4') || model_id.starts_with('codex-')
}

fn openai_responses_include(provider string, model string) []string {
	if openai_responses_model_supports_reasoning(provider, model) {
		return ['reasoning.encrypted_content']
	}
	return []
}

fn openai_responses_reasoning(provider string, model string) ?OpenAIResponsesReasoning {
	if !openai_responses_model_supports_reasoning(provider, model) {
		return none
	}
	return OpenAIResponsesReasoning{
		effort:  'high'
		summary: 'auto'
	}
}

fn openai_responses_failure_message(event OpenAIResponsesEvent) string {
	if event.error.message != '' { return event.error.message }
	if event.response.error.message != '' { return event.response.error.message }
	return 'provider response failed'
}

fn openai_responses_input(messages []ChatMessage) ![]json2.Any {
	mut input := []json2.Any{}
	for message in messages {
		if message.role == 'assistant' {
			for context_item in message.provider_context {
				item := json2.decode[json2.Any](context_item) or {
					return error('provider reasoning context is invalid')
				}
				input << item
			}
		}
		if message.role == 'tool' {
			if message.tool_call_id.len == 0 || message.tool_call_id.len > 64 {
				return error('provider tool call ID is invalid for Responses API')
			}
			input << json2.Any({
				'type':    json2.Any('function_call_output')
				'call_id': json2.Any(message.tool_call_id)
				'output':  json2.Any(message.content)
			})
			continue
		}
		if message.role !in ['system', 'user', 'assistant'] {
			return error('provider message role is unsupported')
		}
		if message.content != '' {
			mut item := map[string]json2.Any{
				'type':    json2.Any('message')
				'role':    json2.Any(message.role)
				'content': json2.Any(message.content)
			}
			if message.role == 'assistant' && message.tool_calls.len > 0 {
				item['phase'] = json2.Any('commentary')
			}
			input << json2.Any(item)
		}
		for call in message.tool_calls {
			if call.id.len == 0 || call.id.len > 64 {
				return error('provider tool call ID is invalid for Responses API')
			}
			mut item := map[string]json2.Any{
				'type':      json2.Any('function_call')
				'call_id':   json2.Any(call.id)
				'name':      json2.Any(call.function.name)
				'arguments': json2.Any(call.function.arguments)
			}
			if call.provider_call_id != '' { item['id'] = json2.Any(call.provider_call_id) }
			input << json2.Any(item)
		}
	}
	return input
}

fn (provider AnthropicProvider) complete(mut turn_ctx vcontext.Context, config ModelConfig,
	messages []ChatMessage,
	tools []AgentToolDefinition, on_text_delta ProviderTextDeltaFn) !CompletionOutput {
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
		stream:     true
	}
	mut stream_state := &AnthropicStreamOutput{}
	callback := fn [mut stream_state, on_text_delta] (data string) ! {
		event := json2.decode[AnthropicStreamEvent](data) or { return error('response_parse') }
		if event.index < 0 || event.index > 128 {
			return error('invalid streamed block index')
		}
		if event.type == 'content_block_start' && event.content_block.type == 'tool_use' {
			for stream_state.tools.len <= event.index {
				stream_state.tools << AnthropicStreamToolCall{}
			}
			mut tool := stream_state.tools[event.index]
			tool.id = event.content_block.id
			tool.name = event.content_block.name
			stream_state.tools[event.index] = tool
		} else if event.type == 'content_block_delta' {
			if event.delta.type == 'text_delta' && event.delta.text != '' {
				stream_state.content_parts << event.delta.text
				on_text_delta(event.delta.text)!
			} else if event.delta.type == 'input_json_delta' {
				for stream_state.tools.len <= event.index {
					stream_state.tools << AnthropicStreamToolCall{}
				}
				mut tool := stream_state.tools[event.index]
				tool.arguments += event.delta.partial_json
				if tool.arguments.len > max_provider_response_bytes {
					return error('tool arguments size limit exceeded')
				}
				stream_state.tools[event.index] = tool
			}
		}
	}
	post_model_sse(mut turn_ctx, '${base}/messages', config, json2.encode[AnthropicRequest](request),
		.anthropic, callback)!
	mut content := []string{}
	mut tool_calls := []ProviderToolCall{}
	content << stream_state.content_parts
	for tool in stream_state.tools {
		if tool.id == '' && tool.name == '' && tool.arguments == '' { continue }
		if tool.id == '' || tool.name == '' || tool.arguments == '' {
			return error('incomplete streamed tool call')
		}
		json2.decode[map[string]json2.Any](tool.arguments) or {
			return error('invalid streamed tool arguments')
		}
		tool_calls << ProviderToolCall{
			id:               tool.id
			provider_call_id: tool.id
			type:             'function'
			function:         ProviderFunctionCall{
				name:      tool.name
				arguments: tool.arguments
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
	tools []AgentToolDefinition, on_text_delta ProviderTextDeltaFn) !CompletionOutput {
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
	url := '${base}/models/${model_path}:streamGenerateContent?alt=sse'
	mut stream_state := &GeminiStreamOutput{}
	callback := fn [mut stream_state, on_text_delta, messages] (data string) ! {
		decoded := json2.decode[GeminiResponse](data) or { return error('response_parse') }
		for candidate in decoded.candidates {
			for part in candidate.content.parts {
				if part.text != '' {
					stream_state.content << part.text
					on_text_delta(part.text)!
				}
				if function_call := part.function_call {
					stream_state.tools << ProviderToolCall{
						id:                 if function_call.id != '' {
							function_call.id
						} else {
							'gemini-${messages.len}-${stream_state.tools.len + 1}'
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
		}
	}
	post_model_sse(mut turn_ctx, url, config, json2.encode[GeminiRequest](request), .gemini,
		callback)!
	if stream_state.content.len == 0 && stream_state.tools.len == 0 {
		return error('empty_response')
	}
	return CompletionOutput{
		provider:   config.provider
		model:      config.model
		content:    stream_state.content.join('')
		tool_calls: stream_state.tools
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

fn post_model_sse(mut turn_ctx vcontext.Context, url string, config ModelConfig, payload string,
	auth ModelAuth, on_data ProviderSSEDataFn) !http.Response {
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
	headers.add_custom('Accept', 'text/event-stream')!
	match auth {
		.bearer {
			if config.api_key.len > 0 {
				headers.add_custom('Authorization', 'Bearer ${config.api_key}')!
			}
		}
		.anthropic {
			headers.add_custom('x-api-key', config.api_key)!
			headers.add_custom('anthropic-version', '2023-06-01')!
		}
		.gemini {
			headers.add_custom('x-goog-api-key', config.api_key)!
		}
	}
	mut stream_state := &ProviderSSERequestState{
		decoder: ProviderSSEDecoder{
			on_data: on_data
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
		stop_receiving_limit: max_provider_stream_bytes + 1
		validate:             true
		verify:               provider_tls_verify_path(url)!
		on_progress_body:     fn [mut stream_state, turn_ctx] (_ &http.Request, chunk []u8, _ u64, _ u64, status_code int) ! {
			stream_state.bytes += chunk.len
			if stream_state.bytes > max_provider_stream_bytes {
				return error('provider stream size limit exceeded')
			}
			if status_code < 200 || status_code >= 300 {
				return
			}
			mut active_ctx := turn_ctx
			if context_error := turn_context_error(mut active_ctx) {
				return error(context_error)
			}
			stream_state.decoder.feed(chunk.bytestr())!
		}
	) or { return error(err.msg()) }
	stream_state.decoder.finish()!
	if response.status_code < 200 || response.status_code >= 300 {
		return error('HTTP ${response.status_code}')
	}
	return response
}
