module main

import json2
import os

fn test_anthropic_request_uses_default_max_tokens_when_budget_is_zero() {
	zero := build_anthropic_request(ModelConfig{
		provider:          'anthropic'
		model:             'claude-fixture'
		max_output_tokens: 0
	}, [
		ChatMessage{
			role:    'user'
			content: 'default budget'
		},
	], [])
	assert zero.max_tokens == max_model_output_tokens
	zero_payload := json2.encode[AnthropicRequest](zero)
	zero_root := json2.decode[map[string]json2.Any](zero_payload) or { panic(err) }
	assert (zero_root['max_tokens'] or { panic('missing max_tokens') }).int() == max_model_output_tokens

	explicit := build_anthropic_request(ModelConfig{
		provider:          'anthropic'
		model:             'claude-fixture'
		max_output_tokens: 512
	}, [
		ChatMessage{
			role:    'user'
			content: 'explicit budget'
		},
	], [])
	assert explicit.max_tokens == 512
}

fn test_anthropic_request_emits_ephemeral_cache_control_by_default() {
	prior := os.getenv_opt(anthropic_prompt_cache_env) or { '' }
	os.unsetenv(anthropic_prompt_cache_env)
	defer {
		if prior == '' {
			os.unsetenv(anthropic_prompt_cache_env)
		} else {
			os.setenv(anthropic_prompt_cache_env, prior, true)
		}
	}

	request := build_anthropic_request(ModelConfig{
		provider:          'anthropic'
		model:             'claude-fixture'
		max_output_tokens: 256
	}, [
		ChatMessage{
			role:    'system'
			content: 'You are a fixture assistant with a stable system prefix.'
		},
		ChatMessage{
			role:    'user'
			content: 'Hello'
		},
	], [])
	payload := json2.encode[AnthropicRequest](request)
	root := json2.decode[map[string]json2.Any](payload) or { panic(err) }

	top := (root['cache_control'] or { panic('missing top-level cache_control') }).as_map()
	assert top['type'] or { panic('missing type') }.str() == 'ephemeral'
	assert 'ttl' !in top

	system := (root['system'] or { panic('missing system') }).as_array()
	assert system.len == 1
	block := system[0].as_map()
	assert block['type'] or { panic('missing system type') }.str() == 'text'
	assert block['text'] or { panic('missing system text') }.str().contains('stable system prefix')
	block_cache := (block['cache_control'] or { panic('missing system cache_control') }).as_map()
	assert block_cache['type'] or { panic('missing system cache type') }.str() == 'ephemeral'
}

fn test_anthropic_request_omits_cache_control_when_disabled() {
	prior := os.getenv_opt(anthropic_prompt_cache_env) or { '' }
	os.setenv(anthropic_prompt_cache_env, 'off', true)
	defer {
		if prior == '' {
			os.unsetenv(anthropic_prompt_cache_env)
		} else {
			os.setenv(anthropic_prompt_cache_env, prior, true)
		}
	}

	request := build_anthropic_request(ModelConfig{
		provider:          'anthropic'
		model:             'claude-fixture'
		max_output_tokens: 128
	}, [
		ChatMessage{
			role:    'system'
			content: 'System without cache markers.'
		},
		ChatMessage{
			role:    'user'
			content: 'Ping'
		},
	], [])
	payload := json2.encode[AnthropicRequest](request)
	root := json2.decode[map[string]json2.Any](payload) or { panic(err) }
	assert 'cache_control' !in root

	system := (root['system'] or { panic('missing system') }).as_array()
	block := system[0].as_map()
	assert 'cache_control' !in block
	assert anthropic_prompt_cache_enabled() == false
}

fn test_anthropic_request_supports_1h_ttl() {
	prior := os.getenv_opt(anthropic_prompt_cache_env) or { '' }
	os.setenv(anthropic_prompt_cache_env, '1h', true)
	defer {
		if prior == '' {
			os.unsetenv(anthropic_prompt_cache_env)
		} else {
			os.setenv(anthropic_prompt_cache_env, prior, true)
		}
	}

	request := build_anthropic_request(ModelConfig{
		provider:          'anthropic'
		model:             'claude-fixture'
		max_output_tokens: 64
	}, [
		ChatMessage{
			role:    'user'
			content: 'No system block; top-level only.'
		},
	], [])
	payload := json2.encode[AnthropicRequest](request)
	root := json2.decode[map[string]json2.Any](payload) or { panic(err) }
	top := (root['cache_control'] or { panic('missing top-level cache_control') }).as_map()
	assert top['type'] or { panic('missing type') }.str() == 'ephemeral'
	assert top['ttl'] or { panic('missing ttl') }.str() == '1h'
	assert 'system' !in root
}

fn test_openai_chat_request_emits_prompt_cache_key_by_default() {
	prior_mode := os.getenv_opt(openai_prompt_cache_env) or { '' }
	prior_key := os.getenv_opt(openai_prompt_cache_key_env) or { '' }
	os.unsetenv(openai_prompt_cache_env)
	os.unsetenv(openai_prompt_cache_key_env)
	defer {
		if prior_mode == '' {
			os.unsetenv(openai_prompt_cache_env)
		} else {
			os.setenv(openai_prompt_cache_env, prior_mode, true)
		}
		if prior_key == '' {
			os.unsetenv(openai_prompt_cache_key_env)
		} else {
			os.setenv(openai_prompt_cache_key_env, prior_key, true)
		}
	}

	request := build_openai_chat_request(ModelConfig{
		provider:          'openai'
		model:             'gpt-fixture'
		max_output_tokens: 128
	}, [
		ChatMessage{
			role:    'system'
			content: 'Stable system prefix for cache routing.'
		},
		ChatMessage{
			role:    'user'
			content: 'Hello'
		},
	], [])
	payload := json2.encode[OpenAIRequest](request)
	root := json2.decode[map[string]json2.Any](payload) or { panic(err) }
	assert root['prompt_cache_key'] or { panic('missing prompt_cache_key') }.str() == openai_prompt_cache_default_key
	assert 'prompt_cache_retention' !in root
	assert openai_prompt_cache_enabled() == true
}

fn test_openai_chat_request_omits_cache_fields_when_disabled() {
	prior_mode := os.getenv_opt(openai_prompt_cache_env) or { '' }
	os.setenv(openai_prompt_cache_env, 'off', true)
	defer {
		if prior_mode == '' {
			os.unsetenv(openai_prompt_cache_env)
		} else {
			os.setenv(openai_prompt_cache_env, prior_mode, true)
		}
	}

	request := build_openai_chat_request(ModelConfig{
		provider:          'openai'
		model:             'gpt-fixture'
		max_output_tokens: 64
	}, [
		ChatMessage{
			role:    'user'
			content: 'Ping'
		},
	], [])
	payload := json2.encode[OpenAIRequest](request)
	root := json2.decode[map[string]json2.Any](payload) or { panic(err) }
	assert 'prompt_cache_key' !in root
	assert 'prompt_cache_retention' !in root
	assert openai_prompt_cache_enabled() == false
}

fn test_openai_chat_request_supports_24h_retention_and_custom_key() {
	prior_mode := os.getenv_opt(openai_prompt_cache_env) or { '' }
	prior_key := os.getenv_opt(openai_prompt_cache_key_env) or { '' }
	os.setenv(openai_prompt_cache_env, '24h', true)
	os.setenv(openai_prompt_cache_key_env, 'tenant-a', true)
	defer {
		if prior_mode == '' {
			os.unsetenv(openai_prompt_cache_env)
		} else {
			os.setenv(openai_prompt_cache_env, prior_mode, true)
		}
		if prior_key == '' {
			os.unsetenv(openai_prompt_cache_key_env)
		} else {
			os.setenv(openai_prompt_cache_key_env, prior_key, true)
		}
	}

	request := build_openai_chat_request(ModelConfig{
		provider:          'openai'
		model:             'gpt-fixture'
		max_output_tokens: 64
	}, [
		ChatMessage{
			role:    'user'
			content: 'Cached prefix routing'
		},
	], [])
	payload := json2.encode[OpenAIRequest](request)
	root := json2.decode[map[string]json2.Any](payload) or { panic(err) }
	assert root['prompt_cache_key'] or { panic('missing prompt_cache_key') }.str() == 'tenant-a'
	assert root['prompt_cache_retention'] or { panic('missing prompt_cache_retention') }.str() == '24h'
}

fn test_openai_chat_request_skips_cache_fields_for_compatible_gateways() {
	prior_mode := os.getenv_opt(openai_prompt_cache_env) or { '' }
	os.unsetenv(openai_prompt_cache_env)
	defer {
		if prior_mode == '' {
			os.unsetenv(openai_prompt_cache_env)
		} else {
			os.setenv(openai_prompt_cache_env, prior_mode, true)
		}
	}

	request := build_openai_chat_request(ModelConfig{
		provider:          'openai-compatible'
		model:             'local-fixture'
		max_output_tokens: 32
	}, [
		ChatMessage{
			role:    'user'
			content: 'No OpenAI cache knobs'
		},
	], [])
	payload := json2.encode[OpenAIRequest](request)
	root := json2.decode[map[string]json2.Any](payload) or { panic(err) }
	assert 'prompt_cache_key' !in root
	assert 'prompt_cache_retention' !in root
}

fn test_openai_responses_request_emits_prompt_cache_key() {
	prior_mode := os.getenv_opt(openai_prompt_cache_env) or { '' }
	prior_key := os.getenv_opt(openai_prompt_cache_key_env) or { '' }
	os.setenv(openai_prompt_cache_env, 'in_memory', true)
	os.unsetenv(openai_prompt_cache_key_env)
	defer {
		if prior_mode == '' {
			os.unsetenv(openai_prompt_cache_env)
		} else {
			os.setenv(openai_prompt_cache_env, prior_mode, true)
		}
		if prior_key == '' {
			os.unsetenv(openai_prompt_cache_key_env)
		} else {
			os.setenv(openai_prompt_cache_key_env, prior_key, true)
		}
	}

	request := build_openai_responses_request(ModelConfig{
		provider:          'openai-responses'
		model:             'gpt-fixture'
		max_output_tokens: 96
	}, [
		ChatMessage{
			role:    'user'
			content: 'Responses cache routing'
		},
	], []) or { panic(err) }
	payload := json2.encode[OpenAIResponsesRequest](request)
	root := json2.decode[map[string]json2.Any](payload) or { panic(err) }
	assert root['prompt_cache_key'] or { panic('missing prompt_cache_key') }.str() == openai_prompt_cache_default_key
	assert root['prompt_cache_retention'] or { panic('missing prompt_cache_retention') }.str() == 'in_memory'
}

fn test_openai_responses_request_skips_cache_fields_for_meta() {
	prior_mode := os.getenv_opt(openai_prompt_cache_env) or { '' }
	os.unsetenv(openai_prompt_cache_env)
	defer {
		if prior_mode == '' {
			os.unsetenv(openai_prompt_cache_env)
		} else {
			os.setenv(openai_prompt_cache_env, prior_mode, true)
		}
	}

	request := build_openai_responses_request(ModelConfig{
		provider:          'meta'
		model:             'muse-fixture'
		max_output_tokens: 0
	}, [
		ChatMessage{
			role:    'user'
			content: 'Meta should not get OpenAI cache knobs'
		},
	], []) or { panic(err) }
	payload := json2.encode[OpenAIResponsesRequest](request)
	root := json2.decode[map[string]json2.Any](payload) or { panic(err) }
	assert 'prompt_cache_key' !in root
	assert 'prompt_cache_retention' !in root
	// Meta applies its own output limit when Veasel leaves the budget at zero.
	assert 'max_output_tokens' !in root
}

fn test_meta_responses_request_includes_explicit_output_budget() {
	request := build_openai_responses_request(ModelConfig{
		provider:          'meta'
		model:             'muse-fixture'
		max_output_tokens: 8192
	}, [
		ChatMessage{
			role:    'user'
			content: 'Meta explicit budget'
		},
	], []) or { panic(err) }
	payload := json2.encode[OpenAIResponsesRequest](request)
	root := json2.decode[map[string]json2.Any](payload) or { panic(err) }
	assert (root['max_output_tokens'] or { panic('missing max_output_tokens') }).int() == 8192
}

fn test_anthropic_request_keeps_tool_schemas_without_cache_markers() {
	prior := os.getenv_opt(anthropic_prompt_cache_env) or { '' }
	os.unsetenv(anthropic_prompt_cache_env)
	defer {
		if prior == '' {
			os.unsetenv(anthropic_prompt_cache_env)
		} else {
			os.setenv(anthropic_prompt_cache_env, prior, true)
		}
	}

	tool := AgentToolDefinition{
		name:        'workspace_search'
		description: 'Search workspace files.'
		parameters:  ToolParameters{
			properties: {
				'query': ToolParameter{
					type: 'string'
				}
			}
			required:   ['query']
		}
	}
	request := build_anthropic_request(ModelConfig{
		provider:          'anthropic'
		model:             'claude-fixture'
		max_output_tokens: 64
	}, [
		ChatMessage{
			role:    'user'
			content: 'Find sentinel'
		},
	], [tool])
	payload := json2.encode[AnthropicRequest](request)
	root := json2.decode[map[string]json2.Any](payload) or { panic(err) }
	tools := (root['tools'] or { panic('missing tools') }).as_array()
	assert tools.len == 1
	tool_obj := tools[0].as_map()
	assert tool_obj['name'] or { panic('missing tool name') }.str() == 'workspace_search'
	assert 'cache_control' !in tool_obj
	assert (root['cache_control'] or { panic('missing top-level cache_control') }).as_map()['type'] or {
		panic('missing type')
	}.str() == 'ephemeral'
}

fn test_gemini_request_omits_cached_content_by_default() {
	prior_mode := os.getenv_opt(gemini_prompt_cache_env) or { '' }
	prior_name := os.getenv_opt(gemini_cached_content_env) or { '' }
	os.unsetenv(gemini_prompt_cache_env)
	os.unsetenv(gemini_cached_content_env)
	defer {
		if prior_mode.len == 0 {
			os.unsetenv(gemini_prompt_cache_env)
		} else {
			os.setenv(gemini_prompt_cache_env, prior_mode, true)
		}
		if prior_name.len == 0 {
			os.unsetenv(gemini_cached_content_env)
		} else {
			os.setenv(gemini_cached_content_env, prior_name, true)
		}
	}
	request := build_gemini_request(ModelConfig{
		provider:          'gemini'
		model:             'gemini-fixture'
		max_output_tokens: 64
	}, [
		ChatMessage{
			role:    'user'
			content: 'Say hello'
		},
	], [])
	payload := json2.encode[GeminiRequest](request)
	root := json2.decode[map[string]json2.Any](payload) or { panic(err) }
	assert 'cachedContent' !in root
	assert gemini_prompt_cache_enabled() == true
	assert gemini_cached_content_name() == ''
}

fn test_gemini_request_emits_cached_content_when_configured() {
	prior_mode := os.getenv_opt(gemini_prompt_cache_env) or { '' }
	prior_name := os.getenv_opt(gemini_cached_content_env) or { '' }
	os.unsetenv(gemini_prompt_cache_env)
	os.setenv(gemini_cached_content_env, 'cachedContents/veasel-fixture-cache', true)
	defer {
		if prior_mode.len == 0 {
			os.unsetenv(gemini_prompt_cache_env)
		} else {
			os.setenv(gemini_prompt_cache_env, prior_mode, true)
		}
		if prior_name.len == 0 {
			os.unsetenv(gemini_cached_content_env)
		} else {
			os.setenv(gemini_cached_content_env, prior_name, true)
		}
	}
	request := build_gemini_request(ModelConfig{
		provider:          'gemini'
		model:             'gemini-fixture'
		max_output_tokens: 64
	}, [
		ChatMessage{
			role:    'system'
			content: 'Be concise'
		},
		ChatMessage{
			role:    'user'
			content: 'Say hello'
		},
	], [])
	payload := json2.encode[GeminiRequest](request)
	root := json2.decode[map[string]json2.Any](payload) or { panic(err) }
	assert root['cachedContent'] or { panic('missing cachedContent') }.str() == 'cachedContents/veasel-fixture-cache'
	assert gemini_cached_content_name() == 'cachedContents/veasel-fixture-cache'
}

fn test_gemini_cached_content_name_rejects_unsafe_values() {
	assert normalize_gemini_cached_content_name('veasel-ok')! == 'cachedContents/veasel-ok'
	assert normalize_gemini_cached_content_name('cachedContents/veasel-ok')! == 'cachedContents/veasel-ok'
	mut rejected := 0
	for raw in ['', 'bad\0name', 'bad\nname', 'cachedContents/../escape', 'cachedContents/a/b',
		'has space', 'a'.repeat(300)] {
		_ = normalize_gemini_cached_content_name(raw) or {
			rejected++
			''
		}
	}
	assert rejected == 7
	assert normalize_gemini_cached_content_ttl('') == gemini_cached_content_ttl_default
	assert normalize_gemini_cached_content_ttl('7200s') == '7200s'
	assert normalize_gemini_cached_content_ttl('nope') == gemini_cached_content_ttl_default
	assert normalize_gemini_cached_content_ttl('01s') == gemini_cached_content_ttl_default
	assert normalize_gemini_cached_content_ttl('0s') == gemini_cached_content_ttl_default
	assert normalize_gemini_cached_content_ttl('3600s\0') == gemini_cached_content_ttl_default
}

fn test_gemini_cached_content_name_prefixes_bare_ids() {
	prior_name := os.getenv_opt(gemini_cached_content_env) or { '' }
	os.setenv(gemini_cached_content_env, 'veasel-bare-id', true)
	defer {
		if prior_name.len == 0 {
			os.unsetenv(gemini_cached_content_env)
		} else {
			os.setenv(gemini_cached_content_env, prior_name, true)
		}
	}
	assert gemini_cached_content_name() == 'cachedContents/veasel-bare-id'
}

fn test_gemini_prompt_cache_off_suppresses_cached_content() {
	prior_mode := os.getenv_opt(gemini_prompt_cache_env) or { '' }
	prior_name := os.getenv_opt(gemini_cached_content_env) or { '' }
	os.setenv(gemini_prompt_cache_env, 'off', true)
	os.setenv(gemini_cached_content_env, 'cachedContents/ignored', true)
	defer {
		if prior_mode.len == 0 {
			os.unsetenv(gemini_prompt_cache_env)
		} else {
			os.setenv(gemini_prompt_cache_env, prior_mode, true)
		}
		if prior_name.len == 0 {
			os.unsetenv(gemini_cached_content_env)
		} else {
			os.setenv(gemini_cached_content_env, prior_name, true)
		}
	}
	request := build_gemini_request(ModelConfig{
		provider:          'gemini'
		model:             'gemini-fixture'
		max_output_tokens: 32
	}, [
		ChatMessage{
			role:    'user'
			content: 'Hi'
		},
	], [])
	payload := json2.encode[GeminiRequest](request)
	root := json2.decode[map[string]json2.Any](payload) or { panic(err) }
	assert 'cachedContent' !in root
	assert gemini_prompt_cache_enabled() == false
}

fn test_openai_chat_request_omits_zero_max_tokens() {
	omitted := build_openai_chat_request(ModelConfig{
		provider:          'openai-compatible'
		model:             'fixture'
		max_output_tokens: 0
	}, [
		ChatMessage{
			role:    'user'
			content: 'omit budget'
		},
	], [])
	omitted_payload := json2.encode[OpenAIRequest](omitted)
	omitted_root := json2.decode[map[string]json2.Any](omitted_payload) or { panic(err) }
	assert 'max_tokens' !in omitted_root

	included := build_openai_chat_request(ModelConfig{
		provider:          'openai-compatible'
		model:             'fixture'
		max_output_tokens: 2048
	}, [
		ChatMessage{
			role:    'user'
			content: 'include budget'
		},
	], [])
	included_payload := json2.encode[OpenAIRequest](included)
	included_root := json2.decode[map[string]json2.Any](included_payload) or { panic(err) }
	assert (included_root['max_tokens'] or { panic('missing max_tokens') }).int() == 2048
}

fn test_gemini_request_omits_zero_max_output_tokens() {
	omitted := build_gemini_request(ModelConfig{
		provider:          'gemini'
		model:             'gemini-2.0-flash'
		max_output_tokens: 0
	}, [
		ChatMessage{
			role:    'user'
			content: 'omit budget'
		},
	], [])
	omitted_payload := json2.encode[GeminiRequest](omitted)
	omitted_root := json2.decode[map[string]json2.Any](omitted_payload) or { panic(err) }
	generation := (omitted_root['generationConfig'] or { panic('missing generationConfig') }).as_map()
	assert 'maxOutputTokens' !in generation

	included := build_gemini_request(ModelConfig{
		provider:          'gemini'
		model:             'gemini-2.0-flash'
		max_output_tokens: 1024
	}, [
		ChatMessage{
			role:    'user'
			content: 'include budget'
		},
	], [])
	included_payload := json2.encode[GeminiRequest](included)
	included_root := json2.decode[map[string]json2.Any](included_payload) or { panic(err) }
	included_generation := (included_root['generationConfig'] or {
		panic('missing generationConfig')
	}).as_map()
	assert (included_generation['maxOutputTokens'] or { panic('missing maxOutputTokens') }).int() == 1024
}

fn test_gemini_cached_content_create_body_shape() {
	body := build_gemini_cached_content_create('gemini-2.0-flash', 'veasel-prefix', 'Be concise',
		[
			GeminiContent{
				role:  'user'
				parts: [GeminiPart{
					text: 'Remember the project rules.'
				}]
			},
		], '')
	payload := json2.encode[GeminiCachedContentCreate](body)
	root := json2.decode[map[string]json2.Any](payload) or { panic(err) }
	assert root['model'] or { panic('missing model') }.str() == 'models/gemini-2.0-flash'
	assert root['displayName'] or { panic('missing displayName') }.str() == 'veasel-prefix'
	assert root['ttl'] or { panic('missing ttl') }.str() == gemini_cached_content_ttl_default
	system := (root['systemInstruction'] or { panic('missing systemInstruction') }).as_map()
	parts := (system['parts'] or { panic('missing parts') }).as_array()
	assert parts.len == 1
	assert parts[0].as_map()['text'] or { panic('missing text') }.str() == 'Be concise'
}
