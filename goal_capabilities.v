module main

// Goal dispatch capabilities are deliberately small and local. Admission
// stores portable runner/verifier identifiers, while dispatch resolves them
// against this registry before claiming a task or creating a worktree.
// Unknown identifiers fail closed; capability discovery and remote workers are
// separate milestones. Verifier IDs here are declarative preflight identities
// only: this slice neither executes a verifier nor produces an evidence
// receipt. Receipt binding still requires the independent verifier/fencing
// milestone described in the implementation plan.

pub struct GoalRunnerCapability {
pub:
	id          string
	version     string
	provider_id string
}

pub struct GoalVerifierCapability {
pub:
	id       string
	version  string
	provider string
	model    string
}

pub struct GoalTaskDispatchCapabilities {
pub:
	runner   GoalRunnerCapability
	verifier GoalVerifierCapability
}

fn resolve_goal_runner_capability(id string, permission_mode string) !GoalRunnerCapability {
	clean := id.trim_space()
	if clean == 'local-v' {
		return GoalRunnerCapability{
			id:          clean
			version:     'veasel-local-v1'
			provider_id: ''
		}
	}
	// Installed CLI providers already have a versioned protocol/permission
	// registry. Reuse its fail-closed gate instead of maintaining a second list.
	validate_provider_cli_launch(clean, permission_mode) or {
		return error('goal runner capability is unavailable: ${err.msg()}')
	}
	return GoalRunnerCapability{
		id:          clean
		version:     'provider-cli-v1'
		provider_id: clean
	}
}

fn resolve_goal_verifier_capability(id string) !GoalVerifierCapability {
	clean := id.trim_space()
	version := match clean {
		'review' { 'builtin-review-v1' }
		'independent-review' { 'builtin-independent-review-v1' }
		else { return error('unknown goal verifier capability: ${clean}') }
	}
	return GoalVerifierCapability{
		id:      clean
		version: version
	}
}

fn resolve_goal_task_dispatch_capabilities(task GoalTask, permission_mode string) !GoalTaskDispatchCapabilities {
	mode := if permission_mode.trim_space().len == 0 { 'ask' } else { permission_mode.trim_space() }
	if (task.verifier_provider.trim_space().len == 0) != (task.verifier_model.trim_space().len == 0) {
		return error('goal task verifier provider and model must be selected together')
	}
	if task.verifier == 'independent-review'
		&& (task.verifier_provider.trim_space().len == 0 || task.verifier_model.trim_space().len == 0) {
		return error('independent-review requires an explicit verifier provider and model route')
	}
	base_verifier := resolve_goal_verifier_capability(task.verifier)!
	return GoalTaskDispatchCapabilities{
		runner:   resolve_goal_runner_capability(task.runner, mode)!
		verifier: GoalVerifierCapability{
			...base_verifier
			provider: task.verifier_provider.trim_space()
			model:    task.verifier_model.trim_space()
		}
	}
}
