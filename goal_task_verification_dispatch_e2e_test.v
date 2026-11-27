module main

import json2
import context as vcontext
import net.http
import os
import sync
import time
import uuid

struct GoalVerificationE2ERepoFixture {
	root          string
	worktree      string
	base_sha      string
	candidate_sha string
}

struct GoalVerificationE2EProviderFixture {
	parent_response   string
	reviewer_response string
mut:
	mu               sync.Mutex
	parent_hits      int
	reviewer_hits    int
	reviewer_started chan bool
	release_reviewer chan bool
}

struct GoalVerificationE2ERequestCounts {
	parent   int
	reviewer int
}

fn (mut fixture GoalVerificationE2EProviderFixture) handle(request http.Request) http.Response {
	is_reviewer := request.data.contains('Review only the committed candidate identified below.')
	fixture.mu.lock()
	mut notify_reviewer_started := false
	if is_reviewer {
		fixture.reviewer_hits++
		notify_reviewer_started = fixture.reviewer_hits == 1
	} else {
		fixture.parent_hits++
	}
	response_text := if is_reviewer {
		fixture.reviewer_response
	} else {
		fixture.parent_response
	}
	fixture.mu.unlock()
	if is_reviewer {
		if notify_reviewer_started {
			_ = fixture.reviewer_started.try_push(true)
		}
		deadline := time.sys_mono_now() + u64(10 * time.second)
		mut released := false
		for time.sys_mono_now() < deadline {
			if fixture.release_reviewer.try_pop(mut released) == .success {
				break
			}
			time.sleep(10 * time.millisecond)
		}
	}
	chunk := OpenAIStreamChunk{
		choices: [OpenAIStreamChoice{
			delta: OpenAIStreamDelta{ content: response_text }
		}]
		usage:   OpenAIUsage{
			prompt_tokens:     10
			completion_tokens: 20
			total_tokens:      30
		}
	}
	mut response := http.Response{}
	response.set_status(.ok)
	response.header.set(.content_type, 'text/event-stream')
	response.body = 'data: ${json2.encode(chunk)}\n\ndata: [DONE]\n\n'
	return response
}

fn (mut fixture GoalVerificationE2EProviderFixture) request_counts() GoalVerificationE2ERequestCounts {
	fixture.mu.lock()
	defer { fixture.mu.unlock() }
	return GoalVerificationE2ERequestCounts{
		parent:   fixture.parent_hits
		reviewer: fixture.reviewer_hits
	}
}

fn (mut fixture GoalVerificationE2EProviderFixture) release_remaining_reviewers() {
	for _ in 0 .. max_active_subagent_runs_per_parent {
		_ = fixture.release_reviewer.try_push(true)
	}
}

fn start_goal_verification_e2e_provider(mut fixture GoalVerificationE2EProviderFixture) !(&http.Server, thread) {
	mut server := &http.Server{
		accept_timeout:       100 * time.millisecond
		handler:              fixture
		addr:                 '127.0.0.1:0'
		show_startup_message: false
		worker_num:           8
	}
	server_thread := spawn server.listen_and_serve()
	server.wait_till_running() or {
		server.stop()
		server_thread.wait()
		return error(err.msg())
	}
	return server, server_thread
}

fn new_goal_verification_e2e_repo_fixture() !GoalVerificationE2ERepoFixture {
	parent := os.join_path(os.temp_dir(), 'veasel-goal-dispatch-e2e-${uuid.new_v4().str()}')
	mut keep_fixture := false
	defer {
		if !keep_fixture {
			os.rmdir_all(parent) or {}
		}
	}
	root := os.join_path(parent, 'checkout')
	worktree := os.join_path(parent, 'goal-candidate')
	hooks := os.join_path(parent, 'empty-hooks')
	os.mkdir_all(os.join_path(root, 'docs'))!
	os.mkdir_all(hooks)!
	os.write_file(os.join_path(root, 'docs/README.md'), 'base')!
	_ = run_workspace_git_command_output(root, ['init', '--quiet', '-b', 'main'], 1024)!
	_ = run_workspace_git_command_output(root, ['config', 'user.name', 'Veasel Fixture'], 1024)!
	_ = run_workspace_git_command_output(root, ['config', 'user.email', 'fixture@example.invalid'], 1024)!
	_ = run_workspace_git_command_output(root, ['config', 'core.hooksPath', hooks], 1024)!
	_ = run_workspace_git_command_output(root, ['remote', 'add', 'origin',
		'https://github.com/owner/repo.git'], 1024)!
	_ = run_workspace_git_command_output(root, ['add', '--', 'docs/README.md'], 1024)!
	_ = run_workspace_git_command_output(root,
		['-c', 'commit.gpgsign=false', 'commit', '--no-gpg-sign', '-m', 'base'], 1024)!
	base_sha := run_workspace_git_command_output(root, ['rev-parse', '--verify', 'HEAD'], 1024)!.trim_space()
	_ = run_workspace_git_command_output(root,
		['worktree', 'add', '--detach', worktree, base_sha], 4096)!
	os.write_file(os.join_path(worktree, 'docs/README.md'), 'candidate')!
	_ = run_workspace_git_command_output(worktree, ['add', '--', 'docs/README.md'], 1024)!
	_ = run_workspace_git_command_output(worktree,
		['-c', 'commit.gpgsign=false', 'commit', '--no-gpg-sign', '-m', 'candidate'], 1024)!
	candidate_sha := run_workspace_git_command_output(worktree, ['rev-parse', '--verify', 'HEAD'], 1024)!.trim_space()
	keep_fixture = true
	return GoalVerificationE2ERepoFixture{
		root:          os.real_path(root)
		worktree:      os.real_path(worktree)
		base_sha:      base_sha
		candidate_sha: candidate_sha
	}
}

fn test_goal_worker_completion_dispatches_bound_reviewer_and_persists_one_receipt() {
	fixture := new_goal_verification_e2e_repo_fixture() or { panic(err) }
	defer { os.rmdir_all(os.dir(fixture.root)) or {} }
	root := os.join_path(os.dir(fixture.root), 'veasel-e2e-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	reviewer_response := '{"goal_id":"goal-verifier-e2e","task_id":"review-docs","attempt":"1","repository":"owner/repo","base_sha":"${fixture.base_sha}","candidate_sha":"${fixture.candidate_sha}","verifier_id":"review","verifier_version":"builtin-review-v1","verdict":"pass","evidence":"The committed documentation candidate satisfies the scoped acceptance criterion."}'
	mut provider_fixture := &GoalVerificationE2EProviderFixture{
		parent_response:   'The worker completed the documentation candidate.'
		reviewer_response: reviewer_response
		reviewer_started:  chan bool{cap: max_active_subagent_runs_per_parent}
		release_reviewer:  chan bool{cap: max_active_subagent_runs_per_parent}
	}
	mut server, server_thread := start_goal_verification_e2e_provider(mut provider_fixture) or {
		panic(err)
	}
	defer {
		server.stop()
		server_thread.wait()
	}
	mut store := open_store(os.join_path(root, 'store.sqlite3')) or { panic(err) }
	mut app := new_app(store, os.join_path(root, 'plugins'))
	defer { app.close() }
	defer { provider_fixture.release_remaining_reviewers() }
	app.model_settings.update(ModelSettingsInput{
		provider: 'openai-compatible'
		model:    'review-fixture'
		base_url: 'http://${server.addr}/v1'
		api_key:  'fixture-only'
	}) or { panic(err) }
	goal := GoalAdmission{
		schema_version:          1
		id:                      'goal-verifier-e2e'
		title:                   'Dispatch independent candidate verification'
		authorized_repositories: [GoalRepository{ owner: 'owner', name: 'repo', path: fixture.root }]
		acceptance_criteria:     [GoalCriterion{
			id:           'scoped-change'
			description:  'The change stays within docs.'
			verification: 'Review the exact committed candidate.'
		}]
		deadline:                '2999-01-01T00:00:00Z'
		budget:                  GoalBudget{ max_attempts: 2, wall_seconds: 120, provider_turns: 4 }
		delivery_mode:           'draft'
		tasks:                   [GoalTask{
			id:                'review-docs'
			title:             'Review documentation change'
			repository:        'owner/repo'
			base_sha:          fixture.base_sha
			paths:             ['docs']
			recipe:            'feature'
			runner:            'local-v'
			verifier:          'review'
			verifier_provider: 'openai-compatible'
			verifier_model:    'review-fixture'
		}]
	}
	_ = store.admit_goal(goal) or { panic(err) }
	parent := store.create_session(SessionInput{ title: 'Goal worker', directory: fixture.worktree }) or {
		panic(err)
	}
	claim := store.claim_goal_task_for_session(goal.id, 'review-docs', parent.id) or { panic(err) }
	store.db.exec_param_many("INSERT INTO goal_task_attempt_workspaces (goal_id, task_id, attempt, repository_root, worktree_path, base_sha, status) VALUES (?, ?, 1, ?, ?, ?, 'ready')", [
		goal.id,
		'review-docs',
		fixture.root,
		fixture.worktree,
		fixture.base_sha,
	]) or { panic(err) }
	mut background := vcontext.background()
	mut turn_ctx, cancel := vcontext.with_timeout(mut background, 20 * time.second)
	defer { cancel() }
	_ = app.run_session_message(mut turn_ctx, parent.id, parent, ChatMessageInput{
		content: 'Complete the scoped documentation task.'
	}, claim.session_operation_id, turn_ctx.deadline() or { panic('expected a turn deadline') }) or {
		panic(err)
	}
	assert (store.goal_task_state(goal.id, 'review-docs') or { panic(err) }).status == 'verifying'
	mut deadline := time.sys_mono_now() + u64(10 * time.second)
	mut reviewer_started := false
	for time.sys_mono_now() < deadline {
		if provider_fixture.reviewer_started.try_pop(mut reviewer_started) == .success {
			break
		}
		time.sleep(10 * time.millisecond)
	}
	assert reviewer_started, 'worker completion did not automatically dispatch the reviewer'
	mut counts := provider_fixture.request_counts()
	assert counts.parent == 1
	assert counts.reviewer == 1
	// The reviewer is live but has not produced a receipt. Repeated recovery
	// scans must observe the in-memory dispatch lease and avoid a second run.
	first_scan := spawn fn (app &App) {
		app.resume_goal_task_verification_dispatches()
	}(app)
	second_scan := spawn fn (app &App) {
		app.resume_goal_task_verification_dispatches()
	}(app)
	first_scan.wait()
	second_scan.wait()
	assert provider_fixture.request_counts().reviewer == 1, 'overlapping recovery scans launched duplicate reviewers'
	_ = provider_fixture.release_reviewer.try_push(true)
	deadline = time.sys_mono_now() + u64(10 * time.second)
	mut receipt_count := 0
	for time.sys_mono_now() < deadline {
		receipt_count = store.db.q_int("SELECT COUNT(*) FROM goal_task_verification_receipts WHERE goal_id = 'goal-verifier-e2e' AND task_id = 'review-docs'") or {
			panic(err)
		}
		if receipt_count == 1 {
			break
		}
		time.sleep(10 * time.millisecond)
	}
	assert receipt_count == 1, 'automatic reviewer dispatch did not persist its receipt'
	counts = provider_fixture.request_counts()
	assert counts.parent == 1
	assert counts.reviewer == 1
	assert (store.goal_task_state(goal.id, 'review-docs') or { panic(err) }).status == 'verified'
	assert (store.goal_task_verification_dispatch_candidates() or { panic(err) }).len == 0
	binding_rows := store.db.exec_param_many('SELECT id, status, reviewer_run_id FROM goal_task_verifier_bindings WHERE goal_id = ? AND task_id = ? AND attempt = 1', [
		goal.id,
		'review-docs',
	]) or { panic(err) }
	assert binding_rows.len == 1
	assert binding_rows[0].val(1) == 'consumed'
	assert binding_rows[0].val(2).len > 0
	run := store.get_subagent_run(binding_rows[0].val(2)) or { panic(err) }
	assert run.status == 'completed'
	assert run.agent_id == 'reviewer'
	assert run.workspace_base_commit == fixture.candidate_sha
	assert store.db.q_int("SELECT COUNT(*) FROM goal_task_verification_leases WHERE goal_id = 'goal-verifier-e2e' AND task_id = 'review-docs'") or {
		panic(err)
	} == 0
	app.resume_goal_task_verification_dispatches()
	time.sleep(50 * time.millisecond)
	counts = provider_fixture.request_counts()
	assert counts.parent == 1
	assert counts.reviewer == 1, 'recovery scan must not launch a duplicate reviewer after receipt'
	assert store.db.q_int("SELECT COUNT(*) FROM goal_task_verification_receipts WHERE goal_id = 'goal-verifier-e2e' AND task_id = 'review-docs'") or {
		panic(err)
	} == 1
	receipt_before_delete := store.get_goal_task_verification_receipt_unlocked(goal.id, 'review-docs',
		1) or {
		panic(err)
	}
	store.delete_session(parent.id) or { panic(err) }
	replayed_after_delete := store.record_goal_task_verification_receipt(binding_rows[0].val(0)) or {
		panic(err)
	}
	assert replayed_after_delete.candidate_sha == receipt_before_delete.candidate_sha
	assert replayed_after_delete.reviewer_run_id == receipt_before_delete.reviewer_run_id
	assert replayed_after_delete.evidence == receipt_before_delete.evidence
	assert replayed_after_delete.created_at == receipt_before_delete.created_at
}
