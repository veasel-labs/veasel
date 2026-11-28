module main

import json2

fn test_goal_task_receipt_projection_is_versioned_and_omits_local_paths() {
	verification := GoalTaskVerificationReceipt{
		goal_id:           'goal'
		task_id:           'task'
		attempt:           2
		repository:        'veasel-labs/veasel'
		repository_root:   '/home/user/private/repo'
		worktree_path:     '/home/user/private/worktree'
		base_sha:          'a'.repeat(40)
		candidate_sha:     'b'.repeat(40)
		verifier_id:       'reviewer'
		verifier_version:  '1'
		reviewer_provider: 'codex'
		reviewer_model:    'gpt-test'
		reviewer_run_id:   'run'
		lease_generation:  3
		verdict:           'pass'
		evidence:          'reviewed candidate'
		changed_paths:     ['src/main.v']
		created_at:        '2026-11-27T12:00:00Z'
	}
	acceptance := GoalTaskAcceptanceReceipt{
		goal_id:          'goal'
		task_id:          'task'
		attempt:          2
		repository:       'veasel-labs/veasel'
		base_sha:         'a'.repeat(40)
		candidate_sha:    'b'.repeat(40)
		decision:         'accept'
		actor:            'local-api-bearer'
		integrity_checks: [goal_task_acceptance_check]
		created_at:       '2026-11-27T12:01:00Z'
	}
	projection := project_goal_task_receipts(verification, acceptance, 'goal', 'task', 2) or {
		panic(err)
	}
	encoded := json2.encode[GoalTaskReceiptProjection](projection)
	assert projection.schema_version == 1
	assert encoded.contains('"schema_version":1')
	assert encoded.contains('"candidate_sha":"${'b'.repeat(40)}"')
	assert encoded.contains('"integrity_checks":["${goal_task_acceptance_check}"]')
	assert !encoded.contains('/home/user/private')
	assert !encoded.contains('repository_root')
	assert !encoded.contains('worktree_path')
}

fn test_goal_task_receipt_projection_preserves_absent_receipts_as_null() {
	projection := project_goal_task_receipts(?GoalTaskVerificationReceipt(none),
		?GoalTaskAcceptanceReceipt(none), 'goal', 'task', 1) or { panic(err) }
	encoded := json2.encode[GoalTaskReceiptProjection](projection)
	assert !encoded.contains('"verification_receipt"')
	assert !encoded.contains('"acceptance_receipt"')
}

fn test_goal_task_receipt_projection_rejects_candidate_mismatch() {
	verification := GoalTaskVerificationReceipt{
		repository:    'veasel-labs/veasel'
		base_sha:      'a'.repeat(40)
		candidate_sha: 'b'.repeat(40)
	}
	acceptance := GoalTaskAcceptanceReceipt{
		repository:    'veasel-labs/veasel'
		base_sha:      'a'.repeat(40)
		candidate_sha: 'c'.repeat(40)
	}
	if _ := project_goal_task_receipts(verification, acceptance, 'goal', 'task', 1) {
		assert false, 'mismatched evidence receipts were projected together'
	}
}

fn test_goal_task_receipt_projection_rejects_acceptance_without_verification() {
	acceptance := GoalTaskAcceptanceReceipt{
		repository:    'veasel-labs/veasel'
		base_sha:      'a'.repeat(40)
		candidate_sha: 'b'.repeat(40)
		decision:      'accept'
	}
	if _ := project_goal_task_receipts(?GoalTaskVerificationReceipt(none), acceptance, 'goal',
		'task', 1) {
		assert false, 'acceptance without verification evidence was projected'
	}
}

fn test_goal_task_attempt_path_parser_rejects_noncanonical_and_nonpositive_values() {
	for value in ['', '0', '-1', '01', '1x', '999999999999999999999'] {
		if _ := parse_goal_task_attempt_path(value) {
			assert false, 'invalid attempt path was accepted: ${value}'
		}
	}
	assert parse_goal_task_attempt_path('12') or { panic(err) } == 12
}
