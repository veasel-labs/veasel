module main

import os

fn test_openapi_documents_subagent_and_context_handoff_routes() {
	openapi := os.read_file('docs/openapi.yaml') or { panic(err) }
	for operation_id in ['listSessionSubagents', 'createSessionSubagent', 'getSessionSubagent',
		'cancelSessionSubagent', 'integrateSessionSubagent', 'listSessionContextHandoffs'] {
		assert openapi.contains('operationId: ${operation_id}'), operation_id
	}
	for schema in ['SubagentRun', 'SubagentCreateInput', 'SubagentTargetInput',
		'SubagentIntegrationResponse', 'SubagentIntegrationConflict', 'ContextHandoffArtifact',
		'ContextHandoffMessage'] {
		assert openapi.contains('${schema}:'), schema
	}
}

fn test_openapi_goal_projection_matches_durable_verification_states() {
	openapi := os.read_file('docs/openapi.yaml') or { panic(err) }
	assert openapi.contains('    GoalAdmission:')
	assert openapi.contains('    GoalTasksProjection:')
	assert openapi.contains('    GoalTaskProjectionItem:')
	assert openapi.contains('    GoalPreflightReport:')
	goal_admission := openapi.all_after('    GoalAdmission:').all_before('\n    GoalTasksProjection:')
	assert goal_admission.contains('required: [id, title, repository, base_sha, paths, depends_on, recipe, runner, verifier]')
	assert goal_admission.contains('verifier_provider: { type: string, minLength: 1, maxLength: 128 }')
	assert goal_admission.contains('verifier_model: { type: string, minLength: 1, maxLength: 256 }')
	assert goal_admission.contains('required: [verifier_provider]')
	assert goal_admission.contains('required: [verifier_model]')
	goal_projection := openapi.all_after('    GoalTaskProjectionItem:').all_before('\n    GoalPreflightReport:')
	assert goal_projection.contains('status: { enum: [pending, running, verifying, verified, succeeded, failed, uncertain] }')
	assert goal_projection.contains('status: { enum: [running, verifying, succeeded, failed, uncertain] }')
	assert goal_projection.contains('required: [attempt, status, started_at, ended_at, effective_deadline, lease_expires_at, lease_generation]')
	assert goal_projection.contains('verifier_provider: { type: string }')
	assert goal_projection.contains('verifier_model: { type: string }')
	assert goal_projection.contains('effective_deadline: { type: string }')
	assert goal_projection.contains('lease_expires_at: { type: string }')
	assert goal_projection.contains('lease_generation: { type: integer, minimum: 0 }')
}

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
	assert free_access.contains('OpenCode Go subscriptions')
	assert free_access.contains('Console API key')
	go_access := model_catalog_error_message('opencode-go',
		'model catalog endpoint returned HTTP 403')
	assert go_access.contains('OpenCode Go denied model-list access')
	assert go_access.contains('Go plan/workspace access')
	assert go_access.contains('OpenCode Console API key')
	assert go_access.contains('enter a model ID manually')
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
