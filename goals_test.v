module main

import json2
import os
import rand

fn test_goal_admission_persists_and_replay_cannot_replace_manifest() {
	root := os.join_path(os.temp_dir(), 'veasel-goals-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'veasel.sqlite3')
	goal := example_goal_admission()
	validate_goal_admission(goal) or { panic(err) }
	mut store := open_store(path) or { panic(err) }
	assert (store.admit_goal(goal) or { panic(err) }) == .created
	store.close() or { panic(err) }

	store = open_store(path) or { panic(err) }
	defer { store.close() or {} }
	assert (store.admit_goal(goal) or { panic(err) }) == .replayed
	assert (store.admit_goal(GoalAdmission{ ...goal, title: 'Replacement' }) or { panic(err) }) == .conflict
	assert (store.admitted_goal_manifest(goal.id) or { panic(err) }) == json2.encode(goal,
		escape_unicode: true
		time_as_unix:   true
	)
	assert (store.admitted_goals() or { panic(err) }).len == 1
}

fn test_goal_admission_rejects_bad_scope_and_cyclic_dependencies() {
	goal := example_goal_admission()
	for task in [
		GoalTask{ ...goal.tasks[0], repository: 'foreign/project' },
		GoalTask{ ...goal.tasks[0], base_sha: 'main' },
		GoalTask{ ...goal.tasks[0], paths: ['docs/../secrets'] },
		GoalTask{ ...goal.tasks[0], depends_on: ['prepare'] },
	] {
		validate_goal_admission(GoalAdmission{ ...goal, tasks: [task] }) or { continue }
		assert false, 'accepted invalid goal task'
	}
}

fn test_goal_v2_permissions_validate_and_survive_admission_and_projection() {
	base := example_goal_admission()
	goal := GoalAdmission{
		...base
		schema_version: 2
		policy_ceiling: ['repository.read', 'repository.write', 'process.execute']
		tasks:          base.tasks.map(GoalTask{
			...it
			permissions: ['repository.read', 'repository.write']
		})
	}
	validate_goal_admission(goal) or { panic(err) }
	validate_goal_permission_json_fields(json2.encode(goal), goal) or { panic(err) }
	mut store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	assert (store.admit_goal(goal) or { panic(err) }) == .created
	stored := json2.decode[GoalAdmission](store.admitted_goal_manifest(goal.id) or { panic(err) }) or {
		panic(err)
	}
	assert stored.policy_ceiling == goal.policy_ceiling
	assert stored.tasks[0].permissions == goal.tasks[0].permissions
	projection := project_goal_task_graph(stored) or { panic(err) }
	assert projection.policy_ceiling == goal.policy_ceiling
	assert projection.tasks[0].permissions == goal.tasks[0].permissions
}

fn test_agent_toolkit_goal_v2_export_fixture_is_accepted_and_preserved() {
	raw := os.read_file(os.join_path(os.dir(@FILE), 'testdata', 'agent-toolkit-goal-v2-permissions.json')) or {
		panic(err)
	}
	goal := json2.decode[GoalAdmission](raw) or { panic(err) }
	validate_goal_permission_json_fields(raw, goal) or { panic(err) }
	validate_goal_admission(goal) or { panic(err) }
	projection := project_goal_task_graph(goal) or { panic(err) }
	assert projection.policy_ceiling == ['repository.read', 'repository.write', 'process.execute']
	assert projection.tasks[0].permissions == ['repository.read', 'repository.write']
}

fn test_goal_permission_contract_rejects_unsafe_versions_and_effects() {
	base := example_goal_admission()
	for invalid in [
		GoalAdmission{ ...base, schema_version: 1, policy_ceiling: ['repository.read'] },
		GoalAdmission{ ...base, schema_version: 2, policy_ceiling: ['repository.write'] },
		GoalAdmission{ ...base, schema_version: 2, policy_ceiling: ['repository.read', 'shell.bypass'] },
		GoalAdmission{
			...base
			schema_version: 2
			policy_ceiling: ['repository.read', 'repository.read']
		},
		GoalAdmission{
			...base
			schema_version: 2
			policy_ceiling: ['repository.read']
			tasks:          [GoalTask{
				...base.tasks[0]
				permissions: [
					'repository.read',
					'github.merge',
				]
			}]
		},
	] {
		validate_goal_admission(invalid) or { continue }
		assert false, 'accepted invalid Goal permission declarations'
	}
	permission_goal := GoalAdmission{
		...base
		schema_version: 2
		policy_ceiling: ['repository.read']
		tasks:          [GoalTask{ ...base.tasks[0], permissions: ['repository.read'] }]
	}
	for raw in [
		'{"schema_version":1,"policy_ceiling":[],"tasks":[]}',
		'{"schema_version":1,"tasks":[{"permissions":[]}]}',
	] {
		validate_goal_permission_json_fields(raw, base) or { continue }
		assert false, 'accepted v1 permission fields'
	}
	missing_task_permissions := GoalAdmission{
		...permission_goal
		tasks: [base.tasks[0]]
	}
	validate_goal_permission_json_fields('{"schema_version":2,"policy_ceiling":["repository.read"],"tasks":[{}]}', missing_task_permissions) or {
		return
	}
	assert false, 'accepted Goal v2 without per-task permissions'
	missing_ceiling := GoalAdmission{
		...permission_goal
		policy_ceiling: []
	}
	validate_goal_permission_json_fields('{"schema_version":2,"tasks":[{"permissions":["repository.read"]}]}', missing_ceiling) or {
		return
	}
	assert false, 'accepted Goal v2 without a policy ceiling'
}

fn example_goal_admission() GoalAdmission {
	return GoalAdmission{
		schema_version:          1
		id:                      'sample-goal'
		title:                   'Test the admission contract'
		authorized_repositories: [GoalRepository{
			owner: 'veasel-labs'
			name:  'veasel'
			path:  '/work/veasel'
		}]
		acceptance_criteria:     [GoalCriterion{
			id:           'tests'
			description:  'Tests must pass'
			verification: 'Independent review'
		}]
		deadline:                '2027-01-01T00:00:00Z'
		budget:                  GoalBudget{ max_attempts: 2, wall_seconds: 300, provider_turns: 4 }
		delivery_mode:           'draft'
		tasks:                   [GoalTask{
			id:         'prepare'
			title:      'Prepare changes'
			repository: 'veasel-labs/veasel'
			base_sha:   'e4b1a73e1573293d01e7f0b821a9c61161f165f3'
			paths:      ['docs']
			recipe:     'feature'
			runner:     'local-v'
			verifier:   'independent-review'
		}]
	}
}

fn test_headless_goals_builds_only_scoped_requests() {
	show := parse_headless_goal_args(['show', 'release.1']) or { panic(err) }
	assert show.method == .get
	assert show.path == '/v1/goals/release.1'
	admit := parse_headless_goal_args(['admit', 'goal.json']) or { panic(err) }
	assert admit.method == .post
	assert admit.file == 'goal.json'
	parse_headless_goal_args(['show', '../sessions']) or { return }
	assert false, 'accepted goal id that can change the API path'
}
