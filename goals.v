module main

import db.sqlite
import json2
import time
import veb

struct GoalAdmission {
	schema_version          int
	id                      string
	title                   string
	authorized_repositories []GoalRepository
	acceptance_criteria     []GoalCriterion
	deadline                string
	budget                  GoalBudget
	delivery_mode           string
	tasks                   []GoalTask
}

struct GoalRepository {
	owner string
	name  string
	path  string
}

struct GoalCriterion {
	id           string
	description  string
	verification string
}

struct GoalBudget {
	max_attempts   int
	wall_seconds   int
	provider_turns int
}

struct GoalTask {
	id         string
	title      string
	repository string
	base_sha   string
	paths      []string
	depends_on []string
	recipe     string
	runner     string
	verifier   string
}

struct AdmittedGoal {
	id         string
	title      string
	status     string
	created_at string
}

enum GoalAdmissionResult {
	created
	replayed
	conflict
}

fn migrate_goal_admissions(mut db sqlite.DB) ! {
	db.begin()!
	defer { db.rollback() or {} }
	db.exec('CREATE TABLE IF NOT EXISTS goal_admissions (
		id TEXT PRIMARY KEY NOT NULL,
		title TEXT NOT NULL,
		manifest TEXT NOT NULL,
		created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
	)')!
	db.exec('INSERT INTO schema_migrations (version) VALUES (35)')!
	db.commit()!
}

fn valid_goal_id(value string) bool {
	if value.len == 0 || value.len > 100 || value in ['.', '..'] {
		return false
	}
	for ch in value {
		if !(ch >= `a` && ch <= `z`) && !(ch >= `A` && ch <= `Z`) && !(ch >= `0` && ch <= `9`) && ch !in [
			`-`,
			`_`,
			`.`,
		] {
			return false
		}
	}
	return true
}

fn valid_goal_sha(value string) bool {
	if value.len !in [40, 64] {
		return false
	}
	for ch in value {
		if !(ch >= `0` && ch <= `9`) && !(ch >= `a` && ch <= `f`) {
			return false
		}
	}
	return true
}

fn valid_goal_relative_path(value string) bool {
	if value.contains_any('\\:\0') {
		return false
	}
	for segment in value.split('/') {
		if segment.trim_space() == '' || segment in ['.', '..'] || segment.to_lower() == '.git' {
			return false
		}
	}
	return true
}

fn validate_goal_admission(goal GoalAdmission) ! {
	if goal.schema_version != 1 || !valid_goal_id(goal.id) || !valid_session_title(goal.title) {
		return error('Goal requires schema_version 1, a valid id and a title')
	}
	if goal.delivery_mode !in ['report', 'draft'] {
		return error('Goal delivery_mode must be report or draft')
	}
	time.parse_rfc3339(goal.deadline) or { return error('Goal deadline must use RFC 3339') }
	if goal.budget.max_attempts <= 0 || goal.budget.wall_seconds <= 0 || goal.budget.provider_turns <= 0 {
		return error('Goal budget limits must be positive')
	}
	if goal.authorized_repositories.len == 0 || goal.acceptance_criteria.len == 0 || goal.tasks.len == 0 {
		return error('Goal requires repositories, acceptance criteria and tasks')
	}
	mut repositories := map[string]bool{}
	for repository in goal.authorized_repositories {
		key := '${repository.owner}/${repository.name}'.to_lower()
		if !valid_goal_id(repository.owner) || !valid_goal_id(repository.name)
			|| repository.path.trim_space() == '' || repository.path.contains('\0') || repositories[key] {
			return error('Goal has an invalid or repeated authorized repository')
		}
		repositories[key] = true
	}
	mut criteria := map[string]bool{}
	for criterion in goal.acceptance_criteria {
		if !valid_goal_id(criterion.id) || criteria[criterion.id]
			|| criterion.description.trim_space() == '' || criterion.verification.trim_space() == '' {
			return error('Goal has an invalid or repeated acceptance criterion')
		}
		criteria[criterion.id] = true
	}
	validate_goal_tasks(goal.tasks, repositories)!
}

fn validate_goal_tasks(tasks []GoalTask, repositories map[string]bool) ! {
	mut seen_tasks := map[string]bool{}
	for task in tasks {
		if seen_tasks[task.id] || !valid_goal_id(task.id) || !valid_session_title(task.title) {
			return error('Goal has an invalid or repeated task')
		}
		seen_tasks[task.id] = true
		if !repositories[task.repository.to_lower()] || !valid_goal_sha(task.base_sha)
			|| task.paths.len == 0 || task.runner.trim_space() == '' || task.verifier.trim_space() == ''
			|| task.recipe !in ['research', 'bug', 'feature', 'migration', 'release'] {
			return error('Goal task requires an authorized repository, pinned base, paths, recipe, runner and verifier')
		}
		if task.paths.any(!valid_goal_relative_path(it)) {
			return error('Goal task paths must be relative to an authorized repository')
		}
	}
	_ := ordered_goal_tasks(tasks)!
}

// ordered_goal_tasks validates and returns a stable Kahn traversal. Ready
// tasks and each dependent list retain manifest order, so task-id spelling
// never changes tie ordering. Both admission and the read-only task projection
// use this one O(V+E) graph walk.
fn ordered_goal_tasks(tasks []GoalTask) ![]GoalTask {
	mut task_ids := map[string]bool{}
	mut tasks_by_id := map[string]GoalTask{}
	mut remaining := map[string]int{}
	mut dependents := map[string][]string{}
	for task in tasks {
		if task.id in task_ids {
			return error('Goal has an invalid or repeated task')
		}
		task_ids[task.id] = true
		tasks_by_id[task.id] = task
		remaining[task.id] = task.depends_on.len
	}
	mut ready := []string{}
	for task in tasks {
		if task.depends_on.len == 0 {
			ready << task.id
		}
		mut seen := map[string]bool{}
		for dependency in task.depends_on {
			if dependency !in remaining || seen[dependency] {
				return error('Goal task has an unknown or repeated dependency')
			}
			seen[dependency] = true
			dependents[dependency] << task.id
		}
	}
	for index := 0; index < ready.len; index++ {
		for child in dependents[ready[index]] {
			remaining[child]--
			if remaining[child] == 0 {
				ready << child
			}
		}
	}
	if ready.len != tasks.len {
		return error('Goal task dependencies contain a cycle')
	}
	return ready.map(tasks_by_id[it])
}

fn (mut store Store) admit_goal(goal GoalAdmission) !GoalAdmissionResult {
	store.mu.lock()
	defer { store.mu.unlock() }
	manifest := json2.encode(goal, escape_unicode: true, time_as_unix: true)
	store.db.begin()!
	defer { store.db.rollback() or {} }
	rows := store.db.exec_param('SELECT manifest FROM goal_admissions WHERE id = ?', goal.id)!
	if rows.len != 0 {
		store.db.commit()!
		return if rows[0].val(0) == manifest { .replayed } else { .conflict }
	}
	store.db.exec_param_many('INSERT INTO goal_admissions (id, title, manifest) VALUES (?, ?, ?)',
		[goal.id, goal.title, manifest])!
	seed_goal_task_state(mut store.db, goal)!
	store.db.commit()!
	return .created
}

fn (mut store Store) admitted_goals() ![]AdmittedGoal {
	store.mu.lock()
	defer { store.mu.unlock() }
	rows := store.db.exec('SELECT id, title, created_at FROM goal_admissions ORDER BY created_at DESC, id ASC LIMIT 100')!
	return rows.map(AdmittedGoal{ id: it.val(0), title: it.val(1), status: 'admitted', created_at: it.val(2) })
}

fn (mut store Store) admitted_goal_manifest(id string) !string {
	store.mu.lock()
	defer { store.mu.unlock() }
	rows := store.db.exec_param('SELECT manifest FROM goal_admissions WHERE id = ?', id)!
	return if rows.len == 0 { '' } else { rows[0].val(0) }
}

@['/v1/goals'; post]
pub fn (app &App) admit_goal(mut ctx Context) veb.Result {
	if ctx.req.data.len > 1024 * 1024 {
		return json_request_error(mut ctx, 'Goal manifest exceeds 1 MiB')
	}
	goal := json2.decode[GoalAdmission](ctx.req.data) or {
		return json_request_error(mut ctx, 'Expected a Goal v1 JSON object')
	}
	validate_goal_admission(goal) or { return json_request_error(mut ctx, err.msg()) }
	mut store := app.store
	result := store.admit_goal(goal) or {
		return json_server_error(mut ctx, 'Unable to admit goal')
	}
	if result == .conflict {
		return json_conflict_error(mut ctx, 'Goal id already identifies a different manifest')
	}
	if result == .created {
		ctx.res.set_status(.created)
	}
	return ctx.json(goal)
}

@['/v1/goals'; get]
pub fn (app &App) list_admitted_goals(mut ctx Context) veb.Result {
	mut store := app.store
	goals := store.admitted_goals() or {
		return json_server_error(mut ctx, 'Unable to list goals')
	}
	return ctx.json(goals)
}

@['/v1/goals/:id'; get]
pub fn (app &App) get_admitted_goal(mut ctx Context, id string) veb.Result {
	mut store := app.store
	manifest := store.admitted_goal_manifest(id) or {
		return json_server_error(mut ctx, 'Unable to read goal')
	}
	if manifest == '' {
		ctx.res.set_status(.not_found)
		return ctx.json(APIError{ error: 'Goal not found' })
	}
	goal := json2.decode[GoalAdmission](manifest) or {
		return json_server_error(mut ctx, 'Unable to decode stored goal')
	}
	return ctx.json(goal)
}
