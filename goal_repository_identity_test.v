module main

import json2
import os
import rand

struct GoalRepositoryIdentityFixture {
	root    string
	outside string
	commit  string
}

fn test_goal_repository_identity_accepts_matching_github_checkout_and_exact_commit() {
	fixture := new_goal_repository_identity_fixture('https://github.com/veasel-labs/veasel.git') or {
		panic(err)
	}
	defer { os.rmdir_all(os.dir(fixture.root)) or {} }
	repository := GoalRepository{
		owner: 'veasel-labs'
		name:  'veasel'
		path:  fixture.root
	}
	task := goal_identity_fixture_task(fixture.commit)
	verified := verify_goal_repository_checkout(repository, [task]) or { panic(err) }
	assert verified.owner == repository.owner
	assert verified.name == repository.name
	assert verified.path == os.real_path(fixture.root)
}

fn test_goal_dispatch_preflight_returns_only_verified_canonical_roots() {
	fixture := new_goal_repository_identity_fixture('https://github.com/veasel-labs/veasel.git') or {
		panic(err)
	}
	defer { os.rmdir_all(os.dir(fixture.root)) or {} }
	goal := GoalAdmission{
		schema_version:          1
		id:                      'preflight-goal'
		title:                   'Preflight repository identity'
		authorized_repositories: [GoalRepository{
			owner: 'veasel-labs'
			name:  'veasel'
			path:  fixture.root
		}]
		acceptance_criteria:     [GoalCriterion{
			id:           'scope'
			description:  'Use the pinned repository'
			verification: 'Inspect the selected worktree'
		}]
		deadline:                '2027-01-01T00:00:00Z'
		budget:                  GoalBudget{ max_attempts: 1, wall_seconds: 60, provider_turns: 1 }
		delivery_mode:           'report'
		tasks:                   [goal_identity_fixture_task(fixture.commit)]
	}
	inspection := inspect_goal_checkouts(goal)
	assert inspection.report.checkouts_validated
	assert inspection.report.repositories[0].identity_verified
	assert !json2.encode(inspection.report).contains('"ready"')
	verified := verify_goal_checkouts(goal) or { panic(err) }
	assert verified.len == 1
	assert verified['veasel-labs/veasel'].path == os.real_path(fixture.root)
}

fn test_goal_checkout_preflight_rejects_elapsed_deadline_and_excess_budget() {
	goal := goal_preflight_test_admission()
	expired := inspect_goal_checkouts(GoalAdmission{ ...goal, deadline: '2000-01-01T00:00:00Z' })
	assert !expired.report.checkouts_validated
	assert expired.report.diagnostics[0].code == 'deadline_elapsed'
	for budget in [
		GoalBudget{ ...goal.budget, max_attempts: max_goal_preflight_attempts + 1 },
		GoalBudget{ ...goal.budget, provider_turns: max_goal_preflight_provider_turns + 1 },
		GoalBudget{ ...goal.budget, wall_seconds: max_goal_preflight_wall_seconds + 1 },
	] {
		result := inspect_goal_checkouts(GoalAdmission{ ...goal, budget: budget })
		assert !result.report.checkouts_validated
		assert result.report.diagnostics[0].code == 'budget_limit'
	}
}

fn test_goal_checkout_preflight_bounds_total_path_checks() {
	goal := goal_preflight_test_admission()
	paths := []string{len: max_goal_total_paths_to_verify + 1, init: 'docs'}
	task := GoalTask{ ...goal.tasks[0], paths: paths }
	limited := inspect_goal_checkouts(GoalAdmission{ ...goal, tasks: [task] })
	assert !limited.report.checkouts_validated
	assert limited.report.diagnostics[0].code == 'verification_limit'
}

fn test_goal_preflight_diagnostics_do_not_echo_checkout_paths_or_remote_credentials() {
	fixture := new_goal_repository_identity_fixture('https://user:private-token@github.com/veasel-labs/veasel.git') or {
		panic(err)
	}
	defer { os.rmdir_all(os.dir(fixture.root)) or {} }
	goal := GoalAdmission{
		schema_version:          1
		id:                      'preflight-diagnostic-goal'
		title:                   'Check safe preflight diagnostics'
		authorized_repositories: [GoalRepository{
			owner: 'veasel-labs'
			name:  'veasel'
			path:  fixture.root
		}]
		acceptance_criteria:     [GoalCriterion{
			id:           'scope'
			description:  'Use the pinned repository'
			verification: 'Inspect the selected worktree'
		}]
		deadline:                '2027-01-01T00:00:00Z'
		budget:                  GoalBudget{ max_attempts: 1, wall_seconds: 60, provider_turns: 1 }
		delivery_mode:           'report'
		tasks:                   [goal_identity_fixture_task(fixture.commit)]
	}
	result := inspect_goal_checkouts(goal)
	assert !result.report.checkouts_validated
	assert result.report.diagnostics.len <= max_goal_repositories_to_verify + 1
	encoded := json2.encode(result.report)
	assert !encoded.contains(fixture.root)
	assert !encoded.contains('private-token')
	assert !encoded.contains('github.com')
}

fn test_goal_repository_identity_rejects_checkout_subdirectory_and_noncanonical_alias() {
	fixture := new_goal_repository_identity_fixture('git@github.com:veasel-labs/veasel.git') or {
		panic(err)
	}
	defer { os.rmdir_all(os.dir(fixture.root)) or {} }
	subdirectory := os.join_path(fixture.root, 'docs')
	if _ := verify_goal_repository_checkout(GoalRepository{
		owner: 'veasel-labs'
		name:  'veasel'
		path:  subdirectory
	}, [goal_identity_fixture_task(fixture.commit)]) {
		assert false, 'accepted a nested directory instead of the checkout root'
	}
	alias := os.join_path(os.dir(fixture.root), 'checkout-alias')
	os.symlink(fixture.root, alias) or { panic(err) }
	if _ := verify_goal_repository_checkout(GoalRepository{
		owner: 'veasel-labs'
		name:  'veasel'
		path:  alias
	}, [goal_identity_fixture_task(fixture.commit)]) {
		assert false, 'accepted a symlink alias as a checkout root'
	}
}

fn test_goal_repository_identity_rejects_wrong_github_remote_and_pushurl() {
	fixture := new_goal_repository_identity_fixture('https://github.com/other/project.git') or {
		panic(err)
	}
	defer { os.rmdir_all(os.dir(fixture.root)) or {} }
	if _ := verify_goal_repository_checkout(GoalRepository{
		owner: 'veasel-labs'
		name:  'veasel'
		path:  fixture.root
	}, [goal_identity_fixture_task(fixture.commit)]) {
		assert false, 'accepted a checkout whose origin identity differs from the manifest'
	}

	fixture2 := new_goal_repository_identity_fixture('https://github.com/veasel-labs/veasel.git') or {
		panic(err)
	}
	defer { os.rmdir_all(os.dir(fixture2.root)) or {} }
	_ = run_workspace_git_command_output(fixture2.root, ['remote', 'set-url', '--push', 'origin',
		'https://github.com/other/project.git'], 1024) or { panic(err) }
	if _ := verify_goal_repository_checkout(GoalRepository{
		owner: 'veasel-labs'
		name:  'veasel'
		path:  fixture2.root
	}, [goal_identity_fixture_task(fixture2.commit)]) {
		assert false, 'accepted a push URL for a different repository'
	}
}

fn test_goal_repository_identity_requires_exact_full_commit_object() {
	fixture := new_goal_repository_identity_fixture('ssh://git@github.com/veasel-labs/veasel.git') or {
		panic(err)
	}
	defer { os.rmdir_all(os.dir(fixture.root)) or {} }
	for base_sha in [fixture.commit[..12], 'f'.repeat(fixture.commit.len)] {
		if _ := verify_goal_repository_checkout(GoalRepository{
			owner: 'veasel-labs'
			name:  'veasel'
			path:  fixture.root
		}, [goal_identity_fixture_task(base_sha)]) {
			assert false, 'accepted an abbreviated or unavailable base commit'
		}
	}
}

fn test_goal_repository_identity_rejects_symlinks_in_pinned_tree_and_checkout() {
	fixture := new_goal_repository_identity_fixture('https://github.com/veasel-labs/veasel.git') or {
		panic(err)
	}
	defer { os.rmdir_all(os.dir(fixture.root)) or {} }
	tracked_link := os.join_path(fixture.root, 'docs', 'linked')
	os.symlink(fixture.outside, tracked_link) or { panic(err) }
	_ = run_workspace_git_command_output(fixture.root, ['add', '--', 'docs/linked'], 1024) or {
		panic(err)
	}
	_ = run_workspace_git_command_output(fixture.root, ['-c', 'commit.gpgsign=false', 'commit',
		'--no-gpg-sign', '-m', 'record link'], 1024) or { panic(err) }
	pinned := run_workspace_git_command_output(fixture.root, ['rev-parse', '--verify', 'HEAD'],
		1024) or { panic(err) }
	if _ := verify_goal_repository_checkout(GoalRepository{
		owner: 'veasel-labs'
		name:  'veasel'
		path:  fixture.root
	}, [GoalTask{ ...goal_identity_fixture_task(pinned.trim_space()), paths: ['docs/linked/secret'] }]) {
		assert false, 'accepted a task scope traversing a pinned symlink'
	}

	mutating_link := os.join_path(fixture.root, 'escape')
	if os.is_link(mutating_link) {
		os.rm(mutating_link) or { panic(err) }
	}
	os.symlink(fixture.outside, mutating_link) or { panic(err) }
	if _ := verify_goal_repository_checkout(GoalRepository{
		owner: 'veasel-labs'
		name:  'veasel'
		path:  fixture.root
	}, [GoalTask{ ...goal_identity_fixture_task(pinned.trim_space()), paths: ['escape/secret'] }]) {
		assert false, 'accepted an untracked working-tree symlink escape'
	}
}

fn test_parse_goal_github_remote_accepts_only_supported_github_forms() {
	for remote in [
		'https://github.com/veasel-labs/veasel.git',
		'ssh://git@github.com/veasel-labs/veasel.git',
		'git@github.com:veasel-labs/veasel.git',
	] {
		owner, name := parse_goal_github_remote(remote) or { panic(err) }
		assert owner == 'veasel-labs'
		assert name == 'veasel'
	}
	for remote in [
		'http://github.com/veasel-labs/veasel.git',
		'https://github.com.attacker.invalid/veasel-labs/veasel.git',
		'https://user:token@github.com/veasel-labs/veasel.git',
		'https://github.com/veasel-labs/veasel.git/extra',
	] {
		if _, _ := parse_goal_github_remote(remote) {
			assert false, 'accepted unsupported or ambiguous remote URL ${remote}'
		}
	}
}

fn goal_preflight_test_admission() GoalAdmission {
	return GoalAdmission{
		schema_version:          1
		id:                      'preflight-test-goal'
		title:                   'Test bounded checkout preflight'
		authorized_repositories: [GoalRepository{
			owner: 'veasel-labs'
			name:  'veasel'
			path:  '/tmp/does-not-need-to-exist'
		}]
		acceptance_criteria:     [GoalCriterion{
			id:           'scope'
			description:  'Check the checkout'
			verification: 'Read the scoped path'
		}]
		deadline:                '2027-01-01T00:00:00Z'
		budget:                  GoalBudget{ max_attempts: 1, wall_seconds: 60, provider_turns: 1 }
		delivery_mode:           'report'
		tasks:                   [GoalTask{
			id:         'inspect'
			title:      'Inspect repository'
			repository: 'veasel-labs/veasel'
			base_sha:   'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
			paths:      ['docs']
			recipe:     'research'
			runner:     'local-v'
			verifier:   'review'
		}]
	}
}

fn goal_identity_fixture_task(base_sha string) GoalTask {
	return GoalTask{
		id:         'verify'
		title:      'Verify checkout'
		repository: 'veasel-labs/veasel'
		base_sha:   base_sha
		paths:      ['docs']
		recipe:     'research'
		runner:     'local-v'
		verifier:   'review'
	}
}

fn new_goal_repository_identity_fixture(remote string) !GoalRepositoryIdentityFixture {
	parent := os.join_path(os.temp_dir(), 'veasel-goal-repository-${rand.ulid()}')
	root := os.join_path(parent, 'checkout')
	outside := os.join_path(parent, 'outside')
	hooks := os.join_path(parent, 'empty-hooks')
	os.mkdir_all(os.join_path(root, 'docs'))!
	os.mkdir_all(outside)!
	os.mkdir_all(hooks)!
	os.write_file(os.join_path(outside, 'secret'), 'outside')!
	os.write_file(os.join_path(root, 'docs', 'README.md'), 'fixture')!
	_ = run_workspace_git_command_output(root, ['init', '--quiet', '-b', 'main'], 1024)!
	_ = run_workspace_git_command_output(root, ['config', 'user.name', 'Veasel Fixture'], 1024)!
	_ = run_workspace_git_command_output(root, ['config', 'user.email', 'fixture@example.invalid'], 1024)!
	_ = run_workspace_git_command_output(root, ['config', 'core.hooksPath', hooks], 1024)!
	_ = run_workspace_git_command_output(root, ['remote', 'add', 'origin', remote], 1024)!
	_ = run_workspace_git_command_output(root, ['add', '--', 'docs/README.md'], 1024)!
	_ = run_workspace_git_command_output(root, ['-c', 'commit.gpgsign=false', 'commit', '--no-gpg-sign',
		'-m', 'fixture'], 1024)!
	commit := run_workspace_git_command_output(root, ['rev-parse', '--verify', 'HEAD'], 1024)!
	return GoalRepositoryIdentityFixture{
		root:    os.real_path(root)
		outside: os.real_path(outside)
		commit:  commit.trim_space()
	}
}
