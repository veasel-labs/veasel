module main

// Provider HTTP failures surface the status with actionable copy, and the
// public text is synthesized from the status alone so untrusted provider
// response text can never leak into the transcript.
fn test_session_turn_failure_names_provider_http_status() {
	auth_status, auth_error := session_turn_failure('HTTP 401 token=fixture-secret')
	assert auth_status == 'failed'
	assert auth_error.contains('rejected the API key (HTTP 401)')
	assert !auth_error.contains('fixture-secret')

	_, denied_error := session_turn_failure('HTTP 403')
	assert denied_error.contains('denied access (HTTP 403)')

	_, missing_error := session_turn_failure('HTTP 404')
	assert missing_error.contains('model or endpoint (HTTP 404)')

	_, limited_error := session_turn_failure('HTTP 429')
	assert limited_error.contains('rate-limited the request (HTTP 429)')

	_, timeout_error := session_turn_failure('HTTP 408')
	assert timeout_error.contains('timed out (HTTP 408)')

	_, upstream_error := session_turn_failure('workspace summary HTTP 502')
	assert upstream_error == 'Model provider request failed (HTTP 502); retry shortly.'

	_, client_error := session_turn_failure('HTTP 400')
	assert client_error == 'Model provider request failed (HTTP 400).'

	_, curated_error := session_turn_failure('OpenCode Go rejected the API key (HTTP 401). Console keys can expire.')
	assert curated_error.contains('rejected the API key (HTTP 401)')
}

fn test_session_turn_failure_names_unreachable_endpoint() {
	refused := 'dial_tcp failed for address 127.0.0.1:53731\ntried addrs:\n\t127.0.0.1:53731: net: socket error: 111; code: 111'
	_, refused_error := session_turn_failure(refused)
	assert refused_error.contains('Could not reach the model provider endpoint')
	assert refused_error.contains('base URL')
	assert !refused_error.contains('127.0.0.1')
	assert !refused_error.contains('111')

	_, dial_error := session_turn_failure('dial_tcp failed for address provider.invalid:443')
	assert dial_error.contains('Could not reach the model provider endpoint')
	assert !dial_error.contains('provider.invalid')

	_, dropped_error := session_turn_failure('response body ended early')
	assert dropped_error.contains('connection dropped before the response completed')
}

fn test_session_turn_failure_keeps_internal_and_generic_mappings() {
	cancelled_status, cancelled_error := session_turn_failure('cancelled')
	assert cancelled_status == 'cancelled'
	assert cancelled_error == 'Turn cancelled.'

	_, deadline_error := session_turn_failure('deadline_exceeded')
	assert deadline_error == 'The assistant turn exceeded its time limit.'

	_, busy_error := session_turn_failure('provider_busy')
	assert busy_error == 'Model provider is at capacity; retry shortly.'

	shutdown_status, shutdown_error := session_turn_failure('app_shutting_down')
	assert shutdown_status == 'cancelled'
	assert shutdown_error == 'The server is shutting down.'

	_, unknown_error := session_turn_failure('boom')
	assert unknown_error == 'The assistant turn failed.'
}
