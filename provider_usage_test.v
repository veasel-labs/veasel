module main

import context as vcontext
import net.http
import strings
import time

struct OpenCodeGoHeaderFixture {
mut:
	hits              int
	path              string
	session_id        string
	user_agent        string
	authorization     string
	api_key_header    string
	google_key_header string
	anthropic_version string
}

fn (mut fixture OpenCodeGoHeaderFixture) handle(request http.Request) http.Response {
	fixture.hits++
	fixture.path = request.url
	fixture.session_id = request.header.get_custom('x-opencode-session') or { '' }
	fixture.user_agent = request.header.get_custom('User-Agent') or { '' }
	fixture.authorization = request.header.get_custom('Authorization') or { '' }
	fixture.api_key_header = request.header.get_custom('x-api-key') or { '' }
	fixture.google_key_header = request.header.get_custom('x-goog-api-key') or { '' }
	fixture.anthropic_version = request.header.get_custom('anthropic-version') or { '' }
	mut response := http.Response{}
	response.set_status(.ok)
	response.header.set(.content_type, 'text/event-stream')
	return response
}

fn start_opencode_go_header_fixture(mut fixture OpenCodeGoHeaderFixture) !(&http.Server, thread) {
	mut server := &http.Server{
		accept_timeout:       100 * time.millisecond
		handler:              fixture
		addr:                 '127.0.0.1:0'
		show_startup_message: false
	}
	server_thread := spawn server.listen_and_serve()
	server.wait_till_running() or {
		server.stop()
		server_thread.wait()
		return error(err.msg())
	}
	return server, server_thread
}

fn test_opencode_go_requests_use_stable_session_ids() {
	assert opencode_go_session_header(ModelConfig{
		provider:   'opencode-go'
		session_id: 'session-123'
	}) == 'session-123'
	assert opencode_go_session_header(ModelConfig{
		provider: 'opencode-go'
	}) == ''
	assert opencode_go_session_header(ModelConfig{
		provider:   'openai-compatible'
		session_id: 'session-123'
	}) == ''
}

fn test_opencode_go_model_catalog_uses_its_separate_discovery_endpoint() {
	info := model_provider_info('opencode-go') or { panic('OpenCode Go provider preset is missing') }
	assert info.base_url == opencode_go_chat_base_url
	assert openai_chat_completions_url(ModelConfig{
		provider: 'opencode-go'
		base_url: info.base_url
	})! == 'https://opencode.ai/inference/go/openai/v1/chat/completions'
	assert provider_model_catalog_url(ModelConfig{
		provider: 'opencode-go'
		base_url: info.base_url
	})! == opencode_go_models_url
	assert provider_model_catalog_url(ModelConfig{
		provider: 'opencode-go'
		base_url: 'https://models.example.test/v1'
	})! == 'https://models.example.test/v1/models'
}

fn test_opencode_go_model_catalog_and_requests_follow_model_api_families() {
	models := [
		ModelCatalogEntry{
			id: 'kimi-k3.1-pro'
		},
		ModelCatalogEntry{
			id: 'kimi-k3'
		},
		ModelCatalogEntry{
			id: 'gpt-6-luna'
		},
		ModelCatalogEntry{
			id: 'claude-haiku-5-5'
		},
		ModelCatalogEntry{
			id: 'gemini-4-argon-contributor'
		},
		ModelCatalogEntry{
			id: 'grok-4.6'
		},
	]
	available := filter_provider_models('opencode-go', models)
	assert available.map(it.id) == ['kimi-k3.1-pro', 'kimi-k3', 'gpt-6-luna', 'claude-haiku-5-5',
		'gemini-4-argon-contributor']

	kimi := model_provider_route(ModelConfig{
		provider: 'opencode-go'
		base_url: opencode_go_chat_base_url
		model:    'kimi-k3.1-pro'
	}) or { panic(err) }
	assert kimi.protocol == 'openai-compatible'
	assert kimi.base_url == opencode_go_openai_base_url

	chat := model_provider_route(ModelConfig{
		provider: 'opencode-go'
		base_url: opencode_go_chat_base_url
		model:    'kimi-k3'
	}) or { panic(err) }
	assert chat.protocol == 'openai-compatible'
	assert chat.base_url == opencode_go_openai_base_url

	responses := model_provider_route(ModelConfig{
		provider: 'opencode-go'
		base_url: opencode_go_chat_base_url
		model:    'gpt-6-luna'
	}) or { panic(err) }
	assert responses.protocol == 'openai-responses'
	assert responses.base_url == opencode_go_openai_base_url

	claude := model_provider_route(ModelConfig{
		provider: 'opencode-go'
		base_url: opencode_go_chat_base_url
		model:    'claude-haiku-5-5'
	}) or { panic(err) }
	assert claude.protocol == 'anthropic'
	assert claude.base_url == opencode_go_anthropic_base_url

	gemini := model_provider_route(ModelConfig{
		provider: 'opencode-go'
		base_url: opencode_go_chat_base_url
		model:    'gemini-4-argon-contributor'
	}) or { panic(err) }
	assert gemini.protocol == 'gemini'
	assert gemini.base_url == opencode_go_google_base_url

	unknown := model_provider_route(ModelConfig{
		provider: 'opencode-go'
		base_url: opencode_go_chat_base_url
		model:    'unknown-go-model'
	}) or {
		assert err.msg().contains('no supported API mapping')
		return
	}
	assert unknown.protocol == ''
}

fn test_opencode_go_invalid_key_error_explains_how_to_recover() {
	message := provider_http_error_message('opencode-go', 401, '')
	assert message.contains('HTTP 401')
	assert message.contains('OpenCode Console')
	assert message.contains('create a new key')
	assert message.contains('signing in again does not renew it')
	access_denied := provider_http_error_message('opencode-go', 403,
		'model catalog endpoint returned')
	assert access_denied.contains('HTTP 403')
	assert access_denied.contains('subscription')
	assert access_denied.contains('workspace')
	assert access_denied.contains('region or privacy restrictions')
	rate_limited := provider_http_error_message('opencode-go', 429, '')
	assert rate_limited.contains('HTTP 429')
	assert rate_limited.contains('rate-limited')
	assert rate_limited.contains('usage limits')
	assert provider_http_error_message('openai-compatible', 401, '') == 'HTTP 401'
}

fn test_opencode_go_turn_sends_required_session_and_client_headers() {
	mut fixture := &OpenCodeGoHeaderFixture{}
	mut server, server_thread := start_opencode_go_header_fixture(mut fixture) or { panic(err) }
	defer {
		server.stop()
		server_thread.wait()
	}
	mut background := vcontext.background()
	mut turn_ctx, cancel := vcontext.with_timeout(mut background, 5 * time.second)
	defer {
		cancel()
	}
	session_id := 'f40de9bc-2bce-4b4f-840d-316e2e019570'
	response := post_model_sse(mut turn_ctx, 'http://${server.addr}/v1/chat/completions', ModelConfig{
		provider:   'opencode-go'
		api_key:    'fixture-key'
		session_id: session_id
	}, '{}', .bearer, fn (_ string) ! {}) or { panic(err) }
	assert response.status_code == 200
	assert fixture.hits == 1
	assert fixture.path == '/v1/chat/completions'
	assert fixture.session_id == session_id
	assert fixture.user_agent == 'Veasel Code/${product_version}'
	assert fixture.authorization == 'Bearer fixture-key'
	assert fixture.api_key_header == ''
	assert fixture.google_key_header == ''

	anthropic_response := post_model_sse(mut turn_ctx, 'http://${server.addr}/v1/messages', ModelConfig{
		provider:   'opencode-go'
		api_key:    'fixture-key'
		session_id: session_id
	}, '{}', .anthropic, fn (_ string) ! {}) or { panic(err) }
	assert anthropic_response.status_code == 200
	assert fixture.path == '/v1/messages'
	assert fixture.authorization == 'Bearer fixture-key'
	assert fixture.api_key_header == ''
	assert fixture.anthropic_version == '2023-06-01'

	gemini_response := post_model_sse(mut turn_ctx, 'http://${server.addr}/v1beta/models/test:streamGenerateContent', ModelConfig{
		provider:   'opencode-go'
		api_key:    'fixture-key'
		session_id: session_id
	}, '{}', .gemini, fn (_ string) ! {}) or { panic(err) }
	assert gemini_response.status_code == 200
	assert fixture.path == '/v1beta/models/test:streamGenerateContent'
	assert fixture.authorization == 'Bearer fixture-key'
	assert fixture.google_key_header == ''
}

fn test_openai_chat_usage_parses_cached_tokens_subset() {
	usage := provider_usage_from_fixture_json('openai-chat', '{
		"prompt_tokens": 1200,
		"completion_tokens": 40,
		"total_tokens": 1240,
		"prompt_tokens_details": {"cached_tokens": 900}
	}') or { panic(err) }
	assert usage.reported
	assert usage.input_tokens == 1200
	assert usage.output_tokens == 40
	assert usage.total_tokens == 1240
	assert usage.cache_reported
	assert usage.cache_read_tokens == 900
	assert usage.cache_creation_tokens == 0
}

fn test_openai_chat_usage_omits_cache_when_details_absent() {
	usage := provider_usage_from_fixture_json('openai-chat', '{
		"prompt_tokens": 100,
		"completion_tokens": 10,
		"total_tokens": 110
	}') or { panic(err) }
	assert usage.reported
	assert usage.input_tokens == 100
	assert !usage.cache_reported
	assert usage.cache_read_tokens == 0
	assert usage.cache_creation_tokens == 0
}

fn test_openai_responses_usage_parses_cache_read_and_write() {
	usage := provider_usage_from_fixture_json('openai-responses', '{
		"input_tokens": 2000,
		"output_tokens": 50,
		"total_tokens": 2050,
		"input_tokens_details": {"cached_tokens": 1500, "cache_write_tokens": 100}
	}') or { panic(err) }
	assert usage.reported
	assert usage.cache_reported
	assert usage.cache_read_tokens == 1500
	assert usage.cache_creation_tokens == 100
	assert !usage.reasoning_reported
}

fn test_openai_chat_usage_parses_reasoning_tokens() {
	usage := provider_usage_from_fixture_json('openai-chat', '{
		"prompt_tokens": 100,
		"completion_tokens": 80,
		"total_tokens": 180,
		"completion_tokens_details": {"reasoning_tokens": 55}
	}') or { panic(err) }
	assert usage.reported
	assert usage.output_tokens == 80
	assert usage.reasoning_reported
	assert usage.reasoning_tokens == 55
}

fn test_openai_responses_usage_parses_reasoning_tokens() {
	usage := provider_usage_from_fixture_json('openai-responses', '{
		"input_tokens": 200,
		"output_tokens": 90,
		"total_tokens": 290,
		"output_tokens_details": {"reasoning_tokens": 40}
	}') or { panic(err) }
	assert usage.reported
	assert usage.reasoning_reported
	assert usage.reasoning_tokens == 40
}

fn test_gemini_usage_parses_thoughts_tokens() {
	usage := provider_usage_from_fixture_json('gemini', '{
		"promptTokenCount": 50,
		"candidatesTokenCount": 20,
		"totalTokenCount": 90,
		"thoughtsTokenCount": 20
	}') or { panic(err) }
	assert usage.reported
	assert usage.reasoning_reported
	assert usage.reasoning_tokens == 20
}

fn test_anthropic_usage_parses_disjoint_cache_fields() {
	usage := provider_usage_from_fixture_json('anthropic', '{
		"input_tokens": 50,
		"output_tokens": 12,
		"cache_read_input_tokens": 100000,
		"cache_creation_input_tokens": 0
	}') or { panic(err) }
	assert usage.reported
	assert usage.input_tokens == 50
	assert usage.output_tokens == 12
	assert usage.cache_reported
	assert usage.cache_read_tokens == 100000
	assert usage.cache_creation_tokens == 0
}

fn test_anthropic_usage_omits_cache_when_fields_absent() {
	usage := provider_usage_from_fixture_json('anthropic', '{
		"input_tokens": 80,
		"output_tokens": 20
	}') or { panic(err) }
	assert usage.reported
	assert !usage.cache_reported
	assert usage.cache_read_tokens == 0
	assert usage.cache_creation_tokens == 0
}

fn test_anthropic_usage_reports_explicit_zero_cache_fields() {
	usage := provider_usage_from_fixture_json('anthropic', '{
		"input_tokens": 80,
		"output_tokens": 20,
		"cache_read_input_tokens": 0,
		"cache_creation_input_tokens": 0
	}') or { panic(err) }
	assert usage.reported
	assert usage.cache_reported
	assert usage.cache_read_tokens == 0
	assert usage.cache_creation_tokens == 0
}

fn test_gemini_usage_parses_cached_content_subset() {
	usage := provider_usage_from_fixture_json('gemini', '{
		"promptTokenCount": 500,
		"candidatesTokenCount": 25,
		"totalTokenCount": 525,
		"cachedContentTokenCount": 400
	}') or { panic(err) }
	assert usage.reported
	assert usage.input_tokens == 500
	assert usage.cache_reported
	assert usage.cache_read_tokens == 400
	assert usage.cache_creation_tokens == 0
}

fn test_gemini_usage_omits_cache_when_field_absent() {
	usage := provider_usage_from_fixture_json('gemini', '{
		"promptTokenCount": 50,
		"candidatesTokenCount": 5,
		"totalTokenCount": 55
	}') or { panic(err) }
	assert usage.reported
	assert !usage.cache_reported
	assert usage.cache_read_tokens == 0
}

fn test_add_provider_usage_sums_cache_only_when_reported() {
	first := ProviderUsage{
		input_tokens:      10
		output_tokens:     2
		total_tokens:      12
		cache_read_tokens: 100
		cache_reported:    true
		reported:          true
	}
	second := ProviderUsage{
		input_tokens:  5
		output_tokens: 1
		total_tokens:  6
		reported:      true
	}
	sum := add_provider_usage(first, second)
	assert sum.input_tokens == 15
	assert sum.output_tokens == 3
	assert sum.cache_reported
	assert sum.cache_read_tokens == 100
}

fn test_anthropic_stream_merges_message_start_and_delta_usage() {
	mut stream_state := AnthropicStreamOutput{}
	anthropic_stream_apply_usage(mut stream_state, 'message_start', '{
		"type":"message_start",
		"message":{"usage":{"input_tokens":120,"output_tokens":0,"cache_read_input_tokens":80,"cache_creation_input_tokens":10}}
	}') or { panic(err) }
	assert stream_state.usage.reported
	assert stream_state.usage.input_tokens == 120
	assert stream_state.usage.output_tokens == 0
	assert stream_state.usage.cache_reported
	assert stream_state.usage.cache_read_tokens == 80
	assert stream_state.usage.cache_creation_tokens == 10
	anthropic_stream_apply_usage(mut stream_state, 'message_delta', '{
		"type":"message_delta",
		"usage":{"output_tokens":40,"cache_read_input_tokens":80,"cache_creation_input_tokens":10}
	}') or { panic(err) }
	merged := stream_state.usage
	assert merged.input_tokens == 120
	assert merged.output_tokens == 40
	assert merged.total_tokens == 160
	assert merged.cache_reported
	assert merged.cache_read_tokens == 80
	assert merged.cache_creation_tokens == 10
}

fn test_provider_stream_tool_arguments_use_bounded_builder() {
	mut arguments := strings.new_builder(16)
	append_provider_stream_tool_arguments(mut arguments, '{"query":')!
	append_provider_stream_tool_arguments(mut arguments, '"sentinel"}')!
	assert arguments.str() == '{"query":"sentinel"}'

	mut full := strings.new_builder(max_provider_response_bytes)
	full.write_string(strings.repeat(`x`, max_provider_response_bytes))
	append_provider_stream_tool_arguments(mut full, 'x') or {
		assert err.msg() == 'tool arguments size limit exceeded'
		return
	}
	assert false, 'tool argument buffer exceeded its size limit'
}

fn test_openai_and_anthropic_usage_clamp_negative_cache_and_reasoning() {
	openai := provider_usage_from_fixture_json('openai-chat', '{
		"prompt_tokens": 10,
		"completion_tokens": 5,
		"total_tokens": 15,
		"prompt_tokens_details": {"cached_tokens": -3},
		"completion_tokens_details": {"reasoning_tokens": -7}
	}') or { panic(err) }
	assert openai.cache_reported
	assert openai.cache_read_tokens == 0
	assert openai.reasoning_reported
	assert openai.reasoning_tokens == 0
	anthropic := provider_usage_from_fixture_json('anthropic', '{
		"input_tokens": 10,
		"output_tokens": 5,
		"cache_read_input_tokens": -2,
		"cache_creation_input_tokens": -4
	}') or { panic(err) }
	assert anthropic.cache_reported
	assert anthropic.cache_read_tokens == 0
	assert anthropic.cache_creation_tokens == 0
}
