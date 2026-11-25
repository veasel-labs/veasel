module main

import json2
import veb

@['/v1/goals/:id/preflight'; get]
pub fn (app &App) preflight_admitted_goal(mut ctx Context, id string) veb.Result {
	if !valid_goal_id(id) {
		ctx.res.set_status(.not_found)
		return ctx.json(APIError{ error: 'Goal not found' })
	}
	mut store := app.store
	manifest := store.admitted_goal_manifest(id) or {
		return json_server_error(mut ctx, 'Unable to read goal')
	}
	if manifest.len == 0 {
		ctx.res.set_status(.not_found)
		return ctx.json(APIError{ error: 'Goal not found' })
	}
	goal := json2.decode[GoalAdmission](manifest) or {
		return json_server_error(mut ctx, 'Unable to decode stored goal')
	}
	return ctx.json(inspect_goal_checkouts(goal).report)
}
