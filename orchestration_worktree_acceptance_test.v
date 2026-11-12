module main

import os
import uuid

// This test exercises the existing isolated-worktree substrate used by
// subagents. It does not claim that a model selected a role, made these edits,
// or that Veasel currently exposes a child-result integration action.
fn test_two_child_worktrees_preserve_parent_and_surface_git_conflicts() {
	git := os.find_abs_path_of_executable('git') or { return }
	_ = git
	root := os.join_path(os.temp_dir(), 'veasel-orchestration-worktrees-${uuid.new_v4().str()}')
	repo := os.join_path(root, 'workspace')
	data := os.join_path(root, 'data')
	os.mkdir_all(repo) or { panic(err) }
	os.mkdir_all(data) or { panic(err) }
	first_id := uuid.new_v4().str()
	second_id := uuid.new_v4().str()
	mut first := SubagentWorkspace{}
	mut second := SubagentWorkspace{}
	integration_path := os.join_path(root, 'integration')
	defer {
		if os.is_dir(integration_path) {
			run_workspace_git_command(repo, ['worktree', 'remove', '--force', integration_path]) or {}
		}
		if second.run_id.len > 0 {
			remove_subagent_workspace(repo, data, second_id, true) or {}
		}
		if first.run_id.len > 0 {
			remove_subagent_workspace(repo, data, first_id, true) or {}
		}
		os.rmdir_all(root) or {}
	}
	_ := run_workspace_git_command(repo, ['init', '-b', 'main']) or { panic(err) }
	_ := run_workspace_git_command(repo, ['config', 'user.email', 'veasel@example.com']) or {
		panic(err)
	}
	_ := run_workspace_git_command(repo, ['config', 'user.name', 'Veasel test']) or { panic(err) }
	os.write_file(os.join_path(repo, 'shared.txt'), 'base\n') or { panic(err) }
	_ := run_workspace_git_command(repo, ['add', 'shared.txt']) or { panic(err) }
	_ := run_workspace_git_command(repo, ['commit', '-m', 'base']) or { panic(err) }

	first = create_subagent_workspace(repo, data, first_id) or { panic(err) }
	second = create_subagent_workspace(repo, data, second_id) or { panic(err) }
	assert first.path != second.path
	assert first.base_commit == second.base_commit
	assert first.branch != second.branch

	// Simulate independently produced, committed child results in the two
	// worktrees. The fixture deliberately makes disjoint file changes plus one
	// overlapping change so Git can report a conflict during review.
	os.write_file(os.join_path(first.path, 'agent-a.txt'), 'result from A\n') or { panic(err) }
	os.write_file(os.join_path(first.path, 'shared.txt'), 'shared from A\n') or { panic(err) }
	_ := run_workspace_git_command(first.path, ['add', 'agent-a.txt', 'shared.txt']) or { panic(err) }
	_ := run_workspace_git_command(first.path, ['commit', '-m', 'child A result']) or { panic(err) }
	os.write_file(os.join_path(second.path, 'agent-b.txt'), 'result from B\n') or { panic(err) }
	os.write_file(os.join_path(second.path, 'shared.txt'), 'shared from B\n') or { panic(err) }
	_ := run_workspace_git_command(second.path, ['add', 'agent-b.txt', 'shared.txt']) or { panic(err) }
	_ := run_workspace_git_command(second.path, ['commit', '-m', 'child B result']) or { panic(err) }

	assert os.read_file(os.join_path(repo, 'shared.txt')) or { panic(err) } == 'base\n'
	assert !os.exists(os.join_path(repo, 'agent-a.txt'))
	assert !os.exists(os.join_path(repo, 'agent-b.txt'))

	// Review in a separate integration checkout. A conflict cannot change the
	// parent's files, and the unresolved integration state can be aborted.
	_ := run_workspace_git_command(repo, ['worktree', 'add', '-b', 'fixture/integration', integration_path,
		'HEAD']) or { panic(err) }
	_ := run_workspace_git_command(integration_path, ['merge', '--no-edit', first.branch]) or {
		panic(err)
	}
	merge_second := run_git_allow_failure(integration_path, ['merge', '--no-edit', second.branch])
	assert merge_second.exit_code != 0, 'overlapping child changes must be reported as a conflict'
	assert os.read_file(os.join_path(integration_path, 'shared.txt')) or { panic(err) }.contains('<<<<<<<')
	assert os.read_file(os.join_path(repo, 'shared.txt')) or { panic(err) } == 'base\n'
	assert !os.exists(os.join_path(repo, 'agent-a.txt'))
	assert !os.exists(os.join_path(repo, 'agent-b.txt'))
	_ := run_workspace_git_command(integration_path, ['merge', '--abort']) or { panic(err) }
	assert os.read_file(os.join_path(integration_path, 'shared.txt')) or { panic(err) } == 'shared from A\n'
}

struct GitFixtureResult {
mut:
	exit_code int
}

fn run_git_allow_failure(directory string, args []string) GitFixtureResult {
	git := os.find_abs_path_of_executable('git') or { panic('git executable is required') }
	mut process := os.new_process(git)
	process.set_args(args)
	process.set_work_folder(directory)
	process.set_redirect_stdio()
	process.run()
	process.wait()
	code := process.code
	process.close()
	return GitFixtureResult{ exit_code: code }
}
