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

fn test_opencode_go_data_use_notices_are_curated_by_provider_and_model() {
	models := [
		ModelCatalogEntry{
			id:             'iceman-contributor-free'
			name:           'Iceman'
			context_tokens: 262144
		},
		ModelCatalogEntry{
			id:   'muse-spark-1.3-contributor'
			name: 'Muse Spark'
		},
		ModelCatalogEntry{
			id:   'unknown-model'
			name: 'Unknown'
		},
	]
	annotated := annotate_model_catalog_with_data_use_notice('opencode-go', models)
	assert annotated[0].data_use_notice or { '' } == 'Prompts may be used to improve this model.'
	assert annotated[0].context_tokens or { 0 } == 262144
	assert annotated[1].data_use_notice or { '' } == 'Prompts may be used to train future Meta models.'
	assert annotated[2].data_use_notice == none

	other_provider := annotate_model_catalog_with_data_use_notice('openai', [models[0]])
	assert other_provider[0].data_use_notice == none
}
