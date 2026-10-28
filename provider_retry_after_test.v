module main

import context as vcontext
import net.http
import time

fn test_provider_retry_after_parses_seconds_dates_and_rejects_invalid_values() {
	now := time.parse_http_header_string('Wed, 28 Oct 2026 12:00:00 GMT') or { panic(err) }
	assert provider_retry_after_ms(' 2 ', now) or { -1 } == 2_000
	assert provider_retry_after_ms('0', now) or { -1 } == 0
	assert provider_retry_after_ms('Wed, 28 Oct 2026 12:00:03 GMT', now) or { -1 } == 3_000
	assert provider_retry_after_ms('Wed, 28 Oct 2026 11:59:00 GMT', now) or { -1 } == 0
	assert provider_retry_after_ms('999999999999999999999999', now) or { -1 } == 2_147_483_647
	for invalid in ['', '-1', '+1', '1.5', 'later', '1, 2', 'x'.repeat(129)] {
		assert provider_retry_after_ms(invalid, now) == none
	}
}

struct RetryAfterHTTPFixture {
	status http.Status
	header string
mut:
	hits int
}

fn (mut fixture RetryAfterHTTPFixture) handle(_ http.Request) http.Response {
	fixture.hits++
	mut response := http.Response{}
	if fixture.hits == 1 {
		response.set_status(fixture.status)
		response.header.set(.retry_after, fixture.header)
		response.body = 'fixture unavailable'
	} else {
		response.set_status(.ok)
		response.header.set(.content_type, 'text/event-stream')
		response.body = 'data: {"choices":[{"delta":{"content":"recovered"}}]}\n\ndata: [DONE]\n\n'
	}
	return response
}

fn test_provider_retry_after_survives_adapter_error_propagation_and_delays_retry() {
	for status in [http.Status.too_many_requests, http.Status.service_unavailable] {
		mut fixture := &RetryAfterHTTPFixture{ status: status, header: '1' }
		mut server := &http.Server{
			addr:                 '127.0.0.1:0'
			handler:              fixture
			accept_timeout:       100 * time.millisecond
			show_startup_message: false
		}
		worker := spawn server.listen_and_serve()
		server.wait_till_running() or { panic(err) }
		mut background := vcontext.background()
		mut ctx, cancel := vcontext.with_timeout(mut background, 10 * time.second)
		started := time.now()
		result := complete_with_turn_context_retry(mut ctx, [ChatMessage{ role: 'user', content: 'fixture' }], [], ignore_provider_text_delta, ModelConfig{
			provider:         'openai-compatible'
			base_url:         'http://${server.addr}/v1'
			model:            'fixture'
			api_key:          'fixture-only'
			request_deadline: ctx.deadline()
		})
		cancel()
		server.stop()
		worker.wait()
		assert result.error == ''
		assert result.output.content == 'recovered'
		assert fixture.hits == 2
		assert time.since(started) >= 950 * time.millisecond
	}
}

fn test_provider_retry_after_outside_deadline_is_not_shortened_or_waited_out() {
	mut background := vcontext.background()
	mut ctx, cancel := vcontext.with_timeout(mut background, 5 * time.second)
	defer { cancel() }
	mut attempts := [0]
	attempt := fn [mut attempts] (mut _ vcontext.Context, _ []ChatMessage, _ []AgentToolDefinition, _ ProviderTextDeltaFn, _ ModelConfig) ProviderTurnResult {
		attempts[0]++
		return ProviderTurnResult{ error: 'HTTP 429', retry_after_ms: 60_000 }
	}
	started := time.now()
	result := complete_with_turn_context_retry_attempts(mut ctx, [], [], ignore_provider_text_delta, ModelConfig{ request_deadline: ctx.deadline() }, attempt)
	assert result.error == 'HTTP 429'
	assert attempts[0] == 1
	assert time.since(started) < time.second
}

fn cancel_retry_after_wait(cancel vcontext.CancelFn) {
	time.sleep(100 * time.millisecond)
	cancel()
}

fn test_retry_after_metadata_never_makes_permanent_errors_retryable() {
	for message in ['HTTP 401', 'HTTP 403', 'HTTP 404', 'provider_busy', 'app_shutting_down'] {
		mut background := vcontext.background()
		mut ctx, cancel := vcontext.with_timeout(mut background, 10 * time.second)
		mut attempts := [0]
		attempt := fn [mut attempts, message] (mut _ vcontext.Context, _ []ChatMessage, _ []AgentToolDefinition, _ ProviderTextDeltaFn, _ ModelConfig) ProviderTurnResult {
			attempts[0]++
			return ProviderTurnResult{
				error:          message
				retry_after_ms: 0
			}
		}
		result := complete_with_turn_context_retry_attempts(mut ctx, [], [], ignore_provider_text_delta,
			ModelConfig{ request_deadline: ctx.deadline() }, attempt)
		cancel()
		assert result.error == message
		assert attempts[0] == 1
	}
}

fn test_provider_retry_after_wait_remains_cancellable() {
	mut background := vcontext.background()
	mut ctx, cancel := vcontext.with_timeout(mut background, 10 * time.second)
	defer { cancel() }
	worker := spawn cancel_retry_after_wait(cancel)
	started := time.now()
	assert !provider_retry_backoff_poll(mut ctx, ctx.deadline(), 5_000)
	worker.wait()
	assert time.since(started) < time.second
}
