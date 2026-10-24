module main

fn test_model_catalog_error_message_explains_provider_auth_rejection() {
	message := model_catalog_error_message('openai', 'model catalog endpoint returned HTTP 401')
	assert message.contains('rejected the API key')
	assert message.contains('HTTP 401')
}

fn test_model_catalog_error_message_explains_permission_and_endpoint_failures() {
	assert model_catalog_error_message('anthropic', 'model catalog endpoint returned HTTP 403').contains('account permissions')
	assert model_catalog_error_message('anthropic', 'model catalog endpoint returned HTTP 404').contains('enter a model ID manually')
	assert model_catalog_error_message('anthropic', 'model catalog endpoint returned HTTP 429').contains('rate-limited')
}

fn test_model_catalog_error_message_does_not_echo_untrusted_provider_errors() {
	message := model_catalog_error_message('openai', 'request failed with token=fixture-secret')
	assert message == 'Unable to retrieve model list from the configured provider endpoint.'
	assert !message.contains('fixture-secret')
}

fn test_opencode_catalog_expired_key_guidance_survives_provider_error_mapping() {
	for provider in ['opencode', 'opencode-go'] {
		provider_error := provider_http_error_message(provider, 401,
			'model catalog endpoint returned')
		message := model_catalog_error_message(provider, provider_error)
		assert message.contains('OpenCode Console')
		assert message.contains('create a new key')
		assert message.contains('renew it')
		assert message.contains('does not reuse the OpenCode CLI login')
	}
}

fn test_opencode_catalog_errors_guide_console_keys_and_go_setup() {
	expired_key := model_catalog_error_message('opencode-go',
		'model catalog endpoint returned HTTP 401')
	assert expired_key.contains('Console keys can expire')
	assert expired_key.contains('signing in again will not renew it')
	assert expired_key.contains('does not reuse the OpenCode CLI login')
	free_access := model_catalog_error_message('opencode',
		'model catalog endpoint returned HTTP 403')
	assert free_access.contains('OpenCode Go preset')
	assert free_access.contains('Console API key')
}
