module main

fn test_model_catalog_error_message_explains_provider_auth_rejection() {
	message := model_catalog_error_message('model catalog endpoint returned HTTP 401')
	assert message.contains('rejected the API key')
	assert message.contains('HTTP 401')
}

fn test_model_catalog_error_message_explains_permission_and_endpoint_failures() {
	assert model_catalog_error_message('model catalog endpoint returned HTTP 403').contains('account permissions')
	assert model_catalog_error_message('model catalog endpoint returned HTTP 404').contains('enter a model ID manually')
	assert model_catalog_error_message('model catalog endpoint returned HTTP 429').contains('rate-limited')
}

fn test_model_catalog_error_message_does_not_echo_untrusted_provider_errors() {
	message := model_catalog_error_message('request failed with token=fixture-secret')
	assert message == 'Unable to retrieve model list from the configured provider endpoint.'
	assert !message.contains('fixture-secret')
}
