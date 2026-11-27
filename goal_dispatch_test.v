module main

fn test_goal_v2_dispatch_fails_closed_before_worker_side_effects() {
	base := example_goal_admission()
	goal := GoalAdmission{
		...base
		schema_version: 2
		policy_ceiling: ['repository.read']
		tasks:          base.tasks.map(GoalTask{ ...it, permissions: ['repository.read'] })
	}
	goal_task_dispatch_policy_supported(goal) or {
		assert err.msg().contains('disabled until task permissions are enforced')
		return
	}
	assert false, 'dispatched a Goal v2 task without enforced permissions'
}

fn test_goal_v1_dispatch_policy_remains_supported() {
	goal_task_dispatch_policy_supported(example_goal_admission()) or { panic(err) }
}
