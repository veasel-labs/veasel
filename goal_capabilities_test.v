module main

fn goal_capability_test_task(runner string, verifier string) GoalTask {
	return GoalTask{
		id:         'task'
		title:      'Task'
		repository: 'owner/repo'
		base_sha:   'a'.repeat(40)
		paths:      ['src']
		recipe:     'feature'
		runner:     runner
		verifier:   verifier
	}
}

fn test_goal_dispatch_resolves_canonical_local_runner_and_verifier() {
	resolved := resolve_goal_task_dispatch_capabilities(goal_capability_test_task('local-v', 'independent-review'), 'ask') or { panic(err) }
	assert resolved.runner.id == 'local-v'
	assert resolved.runner.version == 'veasel-local-v1'
	assert resolved.runner.provider_id == ''
	assert resolved.verifier.id == 'independent-review'
	assert resolved.verifier.version == 'builtin-independent-review-v1'
}

fn test_goal_dispatch_rejects_unknown_runner_before_claim() {
	resolve_goal_task_dispatch_capabilities(goal_capability_test_task('mystery-runner', 'review'), 'ask') or {
		assert err.msg().contains('goal runner capability is unavailable')
		return
	}
	assert false, 'unknown runner was accepted'
}

fn test_goal_dispatch_rejects_unknown_verifier_before_claim() {
	resolve_goal_task_dispatch_capabilities(goal_capability_test_task('local-v', 'mystery-verifier'), 'ask') or {
		assert err.msg().contains('unknown goal verifier capability')
		return
	}
	assert false, 'unknown verifier was accepted'
}

fn test_goal_dispatch_rejects_runner_with_unverified_permission_contract() {
	resolve_goal_task_dispatch_capabilities(goal_capability_test_task('cursor-agent', 'review'), 'ask') or {
		assert err.msg().contains('goal runner capability is unavailable')
		assert err.msg().contains('not launchable')
		return
	}
	assert false, 'blocked runner was accepted'
}
