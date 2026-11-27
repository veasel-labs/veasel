module main

import json2
import veb

pub struct GoalTasksProjection {
pub:
	goal_id        string
	status         string
	policy_ceiling []string @[omitempty]
	tasks          []GoalTaskProjectionItem
}

pub struct GoalTaskProjectionItem {
pub:
	id            string
	title         string
	repository    string
	base_sha      string
	paths         []string
	depends_on    []string
	recipe        string
	runner        string
	verifier      string
	permissions   []string @[omitempty]
	status        string
	attempt_count int
	attempts      []GoalTaskAttemptProjection
}

fn project_goal_task_graph(goal GoalAdmission) !GoalTasksProjection {
	ordered := ordered_goal_tasks(goal.tasks)!
	return GoalTasksProjection{
		goal_id:        goal.id
		status:         'admitted'
		policy_ceiling: goal.policy_ceiling.clone()
		tasks:          ordered.map(goal_task_projection_item(it))
	}
}

fn goal_task_projection_item(task GoalTask) GoalTaskProjectionItem {
	return GoalTaskProjectionItem{
		id:          task.id
		title:       task.title
		repository:  task.repository
		base_sha:    task.base_sha
		paths:       task.paths.clone()
		depends_on:  task.depends_on.clone()
		recipe:      task.recipe
		runner:      task.runner
		verifier:    task.verifier
		permissions: task.permissions.clone()
		status:      'pending'
	}
}

@['/v1/goals/:id/tasks'; get]
pub fn (app &App) get_admitted_goal_tasks(mut ctx Context, id string) veb.Result {
	mut store := app.store
	manifest := store.admitted_goal_manifest(id) or {
		return json_server_error(mut ctx, 'Unable to read goal')
	}
	if manifest == '' {
		ctx.res.set_status(.not_found)
		return ctx.json(APIError{
			error: 'Goal not found'
		})
	}
	goal := json2.decode[GoalAdmission](manifest) or {
		return json_server_error(mut ctx, 'Unable to decode stored goal')
	}
	projection := project_goal_task_graph(goal) or {
		return json_server_error(mut ctx, 'Unable to project admitted goal tasks')
	}
	states := store.goal_task_states_for_goal(id) or {
		return json_server_error(mut ctx, 'Unable to read admitted goal task state')
	}
	mut tasks := projection.tasks.clone()
	for i, task in tasks {
		state := states[task.id] or {
			return json_server_error(mut ctx, 'Unable to read admitted goal task state')
		}
		tasks[i] = GoalTaskProjectionItem{
			...task
			status:        state.status
			attempt_count: state.attempt_count
			attempts:      state.attempts
		}
	}
	current := GoalTasksProjection{
		...projection
		tasks: tasks
	}
	return ctx.json(current)
}
