module main

import json2
import os

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
