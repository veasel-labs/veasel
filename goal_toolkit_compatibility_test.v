module main

import json2
import os
import rand

fn test_agent_toolkit_goal_v1_export_is_admitted_without_semantic_loss() {
	fixture := os.join_path(os.getwd(), 'testdata', 'agent-toolkit-goal-v1-export.json')
	raw := os.read_file(fixture) or { panic(err) }
	goal := json2.decode[GoalAdmission](raw) or { panic(err) }
	validate_goal_admission(goal) or { panic(err) }

	root := os.join_path(os.temp_dir(), 'veasel-toolkit-goal-v1-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	assert (store.admit_goal(goal) or { panic(err) }) == .created
	stored := json2.decode[GoalAdmission](store.admitted_goal_manifest(goal.id) or { panic(err) }) or {
		panic(err)
	}
	assert stored.schema_version == 1
	assert stored.id == goal.id
	assert stored.title == goal.title
	assert stored.authorized_repositories == goal.authorized_repositories
	assert stored.acceptance_criteria == goal.acceptance_criteria
	assert stored.deadline == goal.deadline
	assert stored.budget == goal.budget
	assert stored.delivery_mode == 'draft'
	assert stored.tasks.len == 2
	assert stored.tasks[0].id == 'schema'
	assert stored.tasks[0].title == 'Review goal schema'
	assert stored.tasks[0].repository == 'ulises-jeremias/agent-toolkit'
	assert stored.tasks[0].base_sha == '741c773e9ce790090b06e5fe5834213b6eb8fcf6'
	assert stored.tasks[0].paths == ['schemas']
	assert stored.tasks[0].depends_on.len == 0
	assert stored.tasks[0].recipe == 'feature'
	assert stored.tasks[0].runner == 'local-v'
	assert stored.tasks[0].verifier == 'independent-review'
	assert stored.tasks[0].verifier_provider == ''
	assert stored.tasks[0].verifier_model == ''
	assert stored.tasks[1].id == 'docs'
	assert stored.tasks[1].title == 'Document portable contract'
	assert stored.tasks[1].repository == 'ulises-jeremias/agent-toolkit'
	assert stored.tasks[1].base_sha == '741c773e9ce790090b06e5fe5834213b6eb8fcf6'
	assert stored.tasks[1].depends_on == ['schema']
	assert stored.tasks[1].paths == ['docs']
	assert stored.tasks[1].recipe == 'research'
	assert stored.tasks[1].runner == 'local-v'
	assert stored.tasks[1].verifier == 'independent-review'
	assert stored.tasks[1].verifier_provider == ''
	assert stored.tasks[1].verifier_model == ''
}

fn test_goal_v1_admission_rejects_partial_verifier_route_extension() {
	fixture := os.join_path(os.getwd(), 'testdata', 'agent-toolkit-goal-v1-export.json')
	raw := os.read_file(fixture) or { panic(err) }
	goal := json2.decode[GoalAdmission](raw) or { panic(err) }
	partial_task := GoalTask{
		...goal.tasks[0]
		verifier_provider: 'anthropic'
	}
	invalid_goal := GoalAdmission{
		...goal
		tasks: [partial_task, goal.tasks[1]]
	}
	if _ := validate_goal_admission(invalid_goal) {
		assert false, 'a verifier provider without a model must fail admission'
	} else {
		assert err.msg().contains('verifier provider and model must be supplied together')
	}
}
