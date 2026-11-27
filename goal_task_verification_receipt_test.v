module main

import os
import rand

struct GoalVerificationReceiptRepoFixture {
	root          string
	worktree      string
	base_sha      string
	candidate_sha string
}

fn test_goal_task_verification_receipt_schema_is_migrated_and_idempotent() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-verification-receipt-migration-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'store.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	assert store.db.q_int('SELECT COUNT(*) FROM schema_migrations WHERE version = 43') or {
		panic(err)
	} == 1
	assert store.db.q_int("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('goal_task_verifier_bindings', 'goal_task_verification_receipts')") or {
		panic(err)
	} == 2
	migrate_goal_task_verification_receipts(mut store.db) or { panic(err) }
	assert store.db.q_int("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('goal_task_verifier_bindings', 'goal_task_verification_receipts')") or {
		panic(err)
	} == 2
}

fn test_goal_task_verifier_envelope_requires_exact_bounded_identity_fields() {
	valid := '{"goal_id":"g","task_id":"t","attempt":"1","repository":"owner/repo","base_sha":"${'a'.repeat(40)}","candidate_sha":"${'b'.repeat(40)}","verifier_id":"review","verifier_version":"builtin-review-v1","verdict":"pass","evidence":"Reviewed scoped change."}'
	parsed := parse_goal_task_verifier_envelope(valid) or { panic(err) }
	assert parsed.goal_id == 'g'
	assert parsed.verdict == 'pass'
	assert parsed.evidence == 'Reviewed scoped change.'

	extra := valid.replace('}', ',"unexpected":"field"}')
	if _ := parse_goal_task_verifier_envelope(extra) {
		assert false, 'unexpected fields must fail closed'
	}
	wrong_type := valid.replace('"attempt":"1"', '"attempt":1')
	if _ := parse_goal_task_verifier_envelope(wrong_type) {
		assert false, 'non-string identity fields must fail closed'
	}
	bad_verdict := valid.replace('"verdict":"pass"', '"verdict":"approved"')
	if _ := parse_goal_task_verifier_envelope(bad_verdict) {
		assert false, 'unknown verdicts must fail closed'
	}
	oversized_evidence := valid.replace('Reviewed scoped change.', 'x'.repeat(max_goal_task_verifier_evidence_bytes + 1))
	if _ := parse_goal_task_verifier_envelope(oversized_evidence) {
		assert false, 'oversized evidence must fail closed'
	}
}

fn test_goal_task_verifier_binding_rejects_stale_fence_before_git_observation() {
	root := os.join_path(os.temp_dir(), 'veasel-goal-verification-binding-fence-${rand.ulid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	goal := GoalAdmission{
		schema_version:          1
		id:                      'goal-verifier-fence-test'
		title:                   'Verifier fence test'
		authorized_repositories: [GoalRepository{ owner: 'owner', name: 'repo', path: root }]
		acceptance_criteria:     [GoalCriterion{ id: 'criterion', description: 'Review scoped code', verification: 'A read-only reviewer confirms the change.' }]
		deadline:                '2999-01-01T00:00:00Z'
		budget:                  GoalBudget{ max_attempts: 2, wall_seconds: 120, provider_turns: 4 }
		delivery_mode:           'draft'
		tasks:                   [GoalTask{
			id:         'prepare'
			title:      'Prepare'
			repository: 'owner/repo'
			base_sha:   'a'.repeat(40)
			paths:      ['src']
			recipe:     'feature'
			runner:     'local-v'
			verifier:   'review'
		}]
	}
	mut store := open_store(os.join_path(root, 'store.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	_ = store.admit_goal(goal) or { panic(err) }
	session := store.create_session(SessionInput{ title: 'Verifier fence', directory: root }) or { panic(err) }
	claim := store.claim_goal_task_for_session(goal.id, 'prepare', session.id) or { panic(err) }
	store.db.exec_param_many("INSERT INTO goal_task_attempt_workspaces (goal_id, task_id, attempt, repository_root, worktree_path, base_sha, status) VALUES (?, ?, 1, ?, ?, ?, 'ready')", [
		goal.id,
		'prepare',
		root,
		root,
		goal.tasks[0].base_sha,
	]) or { panic(err) }
	store.reconcile_goal_task_operation(claim.session_operation_id, .succeeded) or { panic(err) }
	lease := store.claim_goal_task_verification_lease(goal.id, 'prepare', 1, 30) or { panic(err) }
	if _ := store.reserve_goal_task_verifier_binding(goal.id, 'prepare', 1, 'stale-token', lease.generation) {
		assert false, 'stale verification fence must fail before repository inspection'
	}
	bindings := store.db.exec_param('SELECT COUNT(*) FROM goal_task_verifier_bindings WHERE goal_id = ?', goal.id) or {
		panic(err)
	}
	assert bindings[0].val(0).int() == 0
}

fn test_goal_task_verification_receipt_binds_real_candidate_and_never_promotes() {
	fixture := new_goal_verification_receipt_repo_fixture() or { panic(err) }
	defer { os.rmdir_all(os.dir(fixture.root)) or {} }
	parent := os.dir(fixture.root)
	worktree_path := fixture.worktree
	candidate_sha := fixture.candidate_sha
	goal := GoalAdmission{
		schema_version:          1
		id:                      'goal-verification-receipt-success'
		title:                   'Review a scoped candidate'
		authorized_repositories: [GoalRepository{
			owner: 'owner'
			name:  'repo'
			path:  fixture.root
		}]
		acceptance_criteria:     [GoalCriterion{
			id:           'candidate-scoped'
			description:  'The committed change stays within docs.'
			verification: 'Read-only reviewer checks the exact commit.'
		}]
		deadline:                '2999-01-01T00:00:00Z'
		budget:                  GoalBudget{ max_attempts: 2, wall_seconds: 120, provider_turns: 4 }
		delivery_mode:           'draft'
		tasks:                   [GoalTask{
			id:         'review-docs'
			title:      'Review documentation change'
			repository: 'owner/repo'
			base_sha:   fixture.base_sha
			paths:      ['docs']
			recipe:     'feature'
			runner:     'local-v'
			verifier:   'review'
		}]
	}
	data_dir := os.join_path(parent, 'veasel-data')
	os.mkdir_all(data_dir) or { panic(err) }
	mut store := open_store(os.join_path(data_dir, 'store.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	_ = store.admit_goal(goal) or { panic(err) }
	session := store.create_session(SessionInput{ title: 'Candidate review', directory: worktree_path }) or {
		panic(err)
	}
	claim := store.claim_goal_task_for_session(goal.id, 'review-docs', session.id) or { panic(err) }
	store.db.exec_param_many("INSERT INTO goal_task_attempt_workspaces (goal_id, task_id, attempt, repository_root, worktree_path, base_sha, status) VALUES (?, ?, 1, ?, ?, ?, 'ready')", [
		goal.id,
		'review-docs',
		fixture.root,
		worktree_path,
		fixture.base_sha,
	]) or { panic(err) }
	store.reconcile_goal_task_operation(claim.session_operation_id, .succeeded) or { panic(err) }
	lease := store.claim_goal_task_verification_lease(goal.id, 'review-docs', 1, 60) or { panic(err) }
	binding := store.reserve_goal_task_verifier_binding(goal.id, 'review-docs', 1,
		lease.fencing_token, lease.generation) or { panic(err) }
	assert binding.candidate_sha == candidate_sha
	assert binding.status == 'reserved'
	prompt := goal_task_verifier_review_prompt(binding, goal, goal.tasks[0])
	run := store.create_subagent_run_with_task(session.id, claim.session_operation_id,
		'verifier-request-1', 'reviewer', 1, 'Goal candidate review', worktree_path, prompt) or {
		panic(err)
	}
	assert run.workspace_ready
	assert run.workspace_base_commit == candidate_sha
	started := store.begin_subagent_run(run.id) or { panic(err) }
	assert started.status == 'running'
	store.create_session_operation(run.child_session_id, run.child_operation_id) or { panic(err) }
	result := '{"goal_id":"${goal.id}","task_id":"review-docs","attempt":"1","repository":"owner/repo","base_sha":"${fixture.base_sha}","candidate_sha":"${candidate_sha}","verifier_id":"review","verifier_version":"builtin-review-v1","verdict":"pass","evidence":"The committed README change is under docs and matches the stated criterion."}'
	finished := store.finish_subagent_run(run.id, 'completed', result, '') or { panic(err) }
	assert finished.status == 'completed'
	store.db.exec_param_many("UPDATE session_operations SET status = 'completed', outcome = 'completed', updated_at = CURRENT_TIMESTAMP WHERE id = ? AND session_id = ? AND status = 'running'", [
		run.child_operation_id,
		run.child_session_id,
	]) or { panic(err) }
	claimed := store.claim_subagent_outcome(finished.id) or { panic(err) }
	assert claimed.outcome_claimed
	bound := store.bind_goal_task_verifier_run(binding.id, claimed.id) or { panic(err) }
	assert bound.status == 'bound'
	assert bound.reviewer_run_id == claimed.id
	receipt := store.record_goal_task_verification_receipt(binding.id) or { panic(err) }
	assert receipt.goal_id == goal.id
	assert receipt.task_id == 'review-docs'
	assert receipt.attempt == 1
	assert receipt.repository == 'owner/repo'
	assert receipt.base_sha == fixture.base_sha
	assert receipt.candidate_sha == candidate_sha
	assert receipt.verifier_id == 'review'
	assert receipt.verifier_version == 'builtin-review-v1'
	assert receipt.reviewer_run_id == claimed.id
	assert receipt.lease_generation == lease.generation
	assert receipt.verdict == 'pass'
	assert receipt.changed_paths == ['docs/README.md']
	assert receipt.evidence.contains('matches the stated criterion')
	state := store.goal_task_state(goal.id, 'review-docs') or { panic(err) }
	assert state.status == 'verifying'
	assert state.attempts[0].status == 'verifying'
	receipt_count := store.db.exec_param_many('SELECT COUNT(*) FROM goal_task_verification_receipts WHERE goal_id = ? AND task_id = ? AND attempt = 1', [
		goal.id,
		'review-docs',
	]) or { panic(err) }
	assert receipt_count[0].val(0).int() == 1
	event_count := store.db.exec_param_many("SELECT COUNT(*) FROM events WHERE session_id = ? AND type = 'goal.task_verification_receipt_recorded'", [session.id]) or {
		panic(err)
	}
	assert event_count[0].val(0).int() == 1
	// Exact replay is idempotent. A conflicting replay cannot mutate the stored
	// evidence or emit another event.
	replayed := store.record_goal_task_verification_receipt(binding.id) or { panic(err) }
	assert replayed.evidence == receipt.evidence
	store.db.exec_param_many('UPDATE subagent_runs SET result = ? WHERE id = ?', [
		result.replace('"verdict":"pass"', '"verdict":"fail"'),
		claimed.id,
	]) or { panic(err) }
	if _ := store.record_goal_task_verification_receipt(binding.id) {
		assert false, 'conflicting reviewer replay must not replace an immutable receipt'
	}
	stored := store.get_goal_task_verification_receipt_unlocked(goal.id, 'review-docs', 1) or {
		panic(err)
	}
	assert stored.verdict == 'pass'
	assert stored.evidence == receipt.evidence
	assert store.goal_task_state(goal.id, 'review-docs') or { panic(err) }.status == 'verifying'
	final_event_count := store.db.exec_param_many("SELECT COUNT(*) FROM events WHERE session_id = ? AND type = 'goal.task_verification_receipt_recorded'", [session.id]) or {
		panic(err)
	}
	assert final_event_count[0].val(0).int() == 1
}

fn new_goal_verification_receipt_repo_fixture() !GoalVerificationReceiptRepoFixture {
	parent := os.join_path(os.temp_dir(), 'veasel-goal-receipt-repo-${rand.ulid()}')
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
	return GoalVerificationReceiptRepoFixture{
		root:          os.real_path(root)
		worktree:      os.real_path(worktree)
		base_sha:      base_sha
		candidate_sha: candidate_sha
	}
}
