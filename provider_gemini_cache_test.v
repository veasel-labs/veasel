module main

import json2
import net.http
import time
import uuid

struct GeminiCachedContentFixture {
mut:
	create_hits int
	delete_hits int
	last_method http.Method
	last_path   string
	last_key    string
	last_body   string
	delete_fail bool
	create_body string = '{"name":"cachedContents/veasel-fixture-cache","model":"models/gemini-2.0-flash","displayName":"veasel-prefix","expireTime":"2026-10-15T20:00:00Z","createTime":"2026-10-15T19:00:00Z","updateTime":"2026-10-15T19:00:00Z"}'
}

fn (mut fixture GeminiCachedContentFixture) handle(request http.Request) http.Response {
	mut response := http.Response{}
	fixture.last_method = request.method
	fixture.last_path = request.url
	fixture.last_key = request.header.get_custom('x-goog-api-key') or { '' }
	fixture.last_body = request.data
	if request.method == .post && request.url == '/cachedContents' {
		fixture.create_hits++
		response.set_status(.ok)
		response.header.set(.content_type, 'application/json')
		response.body = fixture.create_body
		return response
	}
	if request.method == .delete && request.url.starts_with('/cachedContents/') {
		fixture.delete_hits++
		if fixture.delete_fail {
			response.set_status(.not_found)
			response.body = '{"error":{"message":"delete failed"}}'
			return response
		}
		response.set_status(.ok)
		return response
	}
	response.set_status(.not_found)
	return response
}

fn start_gemini_cached_content_fixture(mut fixture GeminiCachedContentFixture) !(&http.Server, thread) {
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

fn test_parse_gemini_cached_content_resource_requires_name() {
	resource := parse_gemini_cached_content_resource('{"name":"cachedContents/ok","model":"models/gemini-2.0-flash"}') or {
		panic(err)
	}
	assert resource.name == 'cachedContents/ok'
	assert resource.model == 'models/gemini-2.0-flash'
	if _ := parse_gemini_cached_content_resource('{"model":"models/gemini-2.0-flash"}') {
		assert false
	}
	if _ := parse_gemini_cached_content_resource('{"name":"cachedContents/../escape"}') {
		assert false
	}
}

fn test_gemini_cached_content_resource_url_escapes_id() {
	url := gemini_cached_content_resource_url('http://127.0.0.1:9/v1beta', 'veasel-ok') or {
		panic(err)
	}
	assert url == 'http://127.0.0.1:9/v1beta/cachedContents/veasel-ok'
	if _ := gemini_cached_content_resource_url('http://127.0.0.1:9/v1beta', 'cachedContents/a/b') {
		assert false
	}
}

fn test_create_and_expire_gemini_cached_content_over_http() {
	mut fixture := &GeminiCachedContentFixture{}
	mut server, server_thread := start_gemini_cached_content_fixture(mut fixture) or { panic(err) }
	defer {
		server.stop()
		server_thread.wait()
	}
	config := ModelConfig{
		provider: 'gemini'
		base_url: 'http://${server.addr}'
		model:    'gemini-2.0-flash'
		api_key:  'fixture-key-${uuid.new_v4().str()}'
	}
	body := build_gemini_cached_content_create(config.model, 'veasel-prefix', 'Be concise',
		[
			GeminiContent{
				role:  'user'
				parts: [GeminiPart{
					text: 'Remember the project rules.'
				}]
			},
		], '7200s')
	created := create_gemini_cached_content(config, body) or { panic(err) }
	assert created.name == 'cachedContents/veasel-fixture-cache'
	assert created.display_name == 'veasel-prefix'
	assert created.expire_time == '2026-10-15T20:00:00Z'
	assert fixture.create_hits == 1
	assert fixture.last_method == .post
	assert fixture.last_path == '/cachedContents'
	assert fixture.last_key == config.api_key
	root := json2.decode[map[string]json2.Any](fixture.last_body) or { panic(err) }
	assert root['model'] or { panic('missing model') }.str() == 'models/gemini-2.0-flash'
	assert root['ttl'] or { panic('missing ttl') }.str() == '7200s'

	expire_gemini_cached_content(config, created.name) or { panic(err) }
	assert fixture.delete_hits == 1
	assert fixture.last_method == .delete
	assert fixture.last_path == '/cachedContents/veasel-fixture-cache'
	assert fixture.last_key == config.api_key
}

fn test_create_gemini_cached_content_rejects_non_gemini_provider() {
	if _ := create_gemini_cached_content(ModelConfig{
		provider: 'openai'
		base_url: 'http://127.0.0.1:9/v1'
		api_key:  'k'
		model:    'gpt'
	}, build_gemini_cached_content_create('gemini-2.0-flash', '', '', [], '')) {
		assert false
	}
}

fn test_expire_gemini_cached_content_propagates_http_errors() {
	mut fixture := &GeminiCachedContentFixture{
		delete_fail: true
	}
	mut server, server_thread := start_gemini_cached_content_fixture(mut fixture) or { panic(err) }
	defer {
		server.stop()
		server_thread.wait()
	}
	expire_gemini_cached_content(ModelConfig{
		provider: 'gemini'
		base_url: 'http://${server.addr}'
		api_key:  'fixture-key'
		model:    'gemini-2.0-flash'
	}, 'cachedContents/missing') or {
		assert err.msg().contains('HTTP 404')
		assert fixture.delete_hits == 1
		return
	}
	assert false
}
