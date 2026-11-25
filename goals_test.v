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
