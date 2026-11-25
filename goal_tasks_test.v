module main

fn test_goal_task_projection_is_stable_topological_order() {
	goal := GoalAdmission{
		id:    'graph'
		tasks: [
			GoalTask{
				id:         'z-final'
				title:      'Final task'
				repository: 'owner/repo'
				base_sha:   'a'.repeat(40)
				paths:      ['src']
				depends_on: ['m-middle', 'a-start']
				recipe:     'feature'
				runner:     'local-v'
				verifier:   'review'
			},
			GoalTask{
				id:         'm-middle'
				title:      'Middle task'
				repository: 'owner/repo'
				base_sha:   'a'.repeat(40)
				paths:      ['src']
				depends_on: ['a-start']
				recipe:     'feature'
				runner:     'local-v'
				verifier:   'review'
			},
			GoalTask{
				id:         'b-independent'
				title:      'Independent task'
				repository: 'owner/repo'
				base_sha:   'a'.repeat(40)
				paths:      ['docs']
				recipe:     'research'
				runner:     'local-v'
				verifier:   'review'
			},
			GoalTask{
				id:         'a-start'
				title:      'Start task'
				repository: 'owner/repo'
				base_sha:   'a'.repeat(40)
				paths:      ['src']
				recipe:     'feature'
				runner:     'local-v'
				verifier:   'review'
			},
		]
	}

	first := project_goal_task_graph(goal) or { panic(err) }
	second := project_goal_task_graph(goal) or { panic(err) }
	assert first.status == 'admitted'
	assert first.tasks.map(it.id) == ['b-independent', 'a-start', 'm-middle', 'z-final']
	assert first.tasks.map(it.status) == ['pending', 'pending', 'pending', 'pending']
	assert first.tasks[3].depends_on == ['m-middle', 'a-start']
	assert first.tasks.map(it.id) == second.tasks.map(it.id)
}

fn test_goal_task_projection_rejects_cycles_and_preserves_large_admitted_graphs() {
	cycle := GoalAdmission{
		id:    'cycle'
		tasks: [
			GoalTask{
				id:         'a'
				title:      'A'
				repository: 'owner/repo'
				base_sha:   'a'.repeat(40)
				paths:      ['src']
				depends_on: ['b']
			},
			GoalTask{
				id:         'b'
				title:      'B'
				repository: 'owner/repo'
				base_sha:   'a'.repeat(40)
				paths:      ['src']
				depends_on: ['a']
			},
		]
	}
	mut cycle_rejected := false
	project_goal_task_graph(cycle) or {
		cycle_rejected = true
		GoalTasksProjection{}
	}
	assert cycle_rejected

	mut large_tasks := []GoalTask{cap: 300}
	for i in 0 .. 300 {
		large_tasks << GoalTask{
			id:         'task-${i:03}'
			title:      'Task ${i}'
			repository: 'owner/repo'
			base_sha:   'a'.repeat(40)
			paths:      ['src']
			recipe:     'feature'
			runner:     'local-v'
			verifier:   'review'
		}
	}
	large_graph := GoalAdmission{
		id:    'large-graph'
		tasks: large_tasks
	}
	large_projection := project_goal_task_graph(large_graph) or { panic(err) }
	assert large_projection.tasks.len == 300
	assert large_projection.tasks.first().id == 'task-000'
	assert large_projection.tasks.last().id == 'task-299'
}
