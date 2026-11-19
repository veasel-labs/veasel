module main

import context as vcontext
import os
import json2
import net
import net.http
import time
import uuid
import veb

struct SubagentIntegrationHTTPServer {
	app          &App
	port         int
	server_ready chan &veb.Server
}

pub fn (mut app SubagentIntegrationHTTPServer) init_server(server &veb.Server) {
	app.server_ready <- server
}

@['/v1/sessions/:id/subagents/:run_id/integrate'; post]
pub fn (mut app SubagentIntegrationHTTPServer) integrate_subagent(mut ctx Context, id string,
	run_id string) veb.Result {
	return app.app.integrate_session_subagent(mut ctx, id, run_id)
}

fn run_subagent_integration_http_test_server(mut app SubagentIntegrationHTTPServer) {
	veb.run_at[SubagentIntegrationHTTPServer, Context](mut app,
		host:   '127.0.0.1'
		family: .ip
		port:   app.port
	) or { panic(err) }
}

fn test_implementer_profile_preserves_parent_policy_and_tool_boundary() {
	profile := builtin_subagent_profile('implementer') or { panic(err) }
	assert profile.tool_policy().allows('workspace_propose_file_edit')
	assert profile.tool_policy().allows('workspace_propose_file_content')
	assert profile.tool_policy().allows('workspace_read_file')
	// #642: the implementer may propose shell commands; execution is routed
	// to the sealed child sandbox by run_session_shell_command, and the
	// parent-policy intersection below still strips the grant when the
	// parent does not allow it.
	assert profile.tool_policy().allows('workspace_propose_shell_command')
	assert !profile.tool_policy().allows('plugin_mcp_tool')

	ask_policy := ExecutionPolicyTurn{ mode: .ask, interactive: true }
	ask_result := ask_policy
	assert ask_result.mode == .ask
	assert ask_result.interactive
	assert decide_execution_permission(ask_result.mode, 'edit', ask_result.interactive, false) == .ask
	assert restrict_agent_tools_for_execution_policy([
		AgentToolDefinition{ name: 'workspace_propose_file_edit' },
	], ask_result).len == 1
	non_interactive_ask := ExecutionPolicyTurn{ mode: .ask, interactive: false }
	assert restrict_agent_tools_for_execution_policy([
		AgentToolDefinition{ name: 'workspace_propose_file_edit' },
	], non_interactive_ask).len == 0
	auto_policy := ExecutionPolicyTurn{ mode: .auto_edit, interactive: false }
	auto_result := auto_policy
	assert auto_result.mode == .auto_edit
	assert !auto_result.interactive
	assert decide_execution_permission(auto_result.mode, 'edit', auto_result.interactive, false) == .allow

	mut parent_tools := map[string]bool{}
	parent_tools['workspace_read_file'] = true
	intersection := intersect_subagent_tool_policy(profile.tool_policy(), AgentToolPolicy{
		restricted:    true
		allowed_tools: parent_tools
	})
	assert intersection.allows('workspace_read_file')
	assert !intersection.allows('workspace_propose_file_edit')
	assert !intersection.allows('workspace_propose_shell_command')
}

fn test_child_integration_creates_parent_proposal_and_applies_only_after_approval() {
	root := os.join_path(os.temp_dir(), 'veasel-child-integration-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	workspace := init_subagent_integration_test_repo(root)
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	mut app := new_app(store, os.join_path(root, 'plugins'))
	defer { app.close() }
	parent := store.create_session(SessionInput{ title: 'Parent', directory: workspace }) or { panic(err) }
	parent_operation := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, parent_operation) or { panic(err) }
	run, child_directory := create_completed_implementer_child(mut store, parent, parent_operation,
		workspace, 'integration-proposal')
	child_path := os.join_path(child_directory, 'README.md')
	os.write_file(child_path, 'implemented in child\n') or { panic(err) }
	os.write_file(os.join_path(child_directory, 'new-file.md'), 'new child file\n') or { panic(err) }
	before := os.read_file(os.join_path(workspace, 'README.md')) or { panic(err) }
	response := app.propose_subagent_integration(parent.id, run.id) or { panic(err) }
	assert response.conflicts.len == 0
	assert response.proposals.len == 2
	assert response.proposals.any(it.path == 'README.md')
	assert response.proposals.any(it.path == 'new-file.md')
	assert os.read_file(os.join_path(workspace, 'README.md')) or { panic(err) } == before
	assert !os.exists(os.join_path(workspace, 'new-file.md'))
	retried := app.propose_subagent_integration(parent.id, run.id) or { panic(err) }
	assert retried.proposals.len == response.proposals.len
	for proposal in response.proposals {
		assert retried.proposals.any(it.id == proposal.id && it.path == proposal.path)
	}

	for proposal in response.proposals {
		_ = store.review_workspace_edit(parent.id, proposal.id) or { panic(err) }
		edit := store.begin_workspace_edit(parent.id, proposal.id) or { panic(err) }
		apply_workspace_edit(workspace, edit) or { panic(err) }
		store.finish_workspace_edit(parent.id, proposal.id, 'applied') or { panic(err) }
	}
	assert os.read_file(os.join_path(workspace, 'README.md')) or { panic(err) } == 'implemented in child\n'
	assert os.read_file(os.join_path(workspace, 'new-file.md')) or { panic(err) } == 'new child file\n'
}

fn test_child_integration_detects_parent_conflict_and_preserves_child_worktree() {
	root := os.join_path(os.temp_dir(), 'veasel-child-conflict-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	workspace := init_subagent_integration_test_repo(root)
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	mut app := new_app(store, os.join_path(root, 'plugins'))
	defer { app.close() }
	parent := store.create_session(SessionInput{ title: 'Parent conflict', directory: workspace }) or {
		panic(err)
	}
	parent_operation := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, parent_operation) or { panic(err) }
	run, child_directory := create_completed_implementer_child(mut store, parent, parent_operation,
		workspace, 'integration-conflict')
	child_content := 'child version\n'
	os.write_file(os.join_path(child_directory, 'README.md'), child_content) or { panic(err) }
	os.write_file(os.join_path(workspace, 'README.md'), 'parent version\n') or { panic(err) }
	response := app.propose_subagent_integration(parent.id, run.id) or { panic(err) }
	assert response.proposals.len == 0
	assert response.conflicts.len == 1
	assert response.conflicts[0].path == 'README.md'
	assert os.read_file(os.join_path(workspace, 'README.md')) or { panic(err) } == 'parent version\n'
	assert os.read_file(os.join_path(child_directory, 'README.md')) or { panic(err) } == child_content
	assert os.is_dir(child_directory)
}

fn test_child_rename_reports_old_path_deletion_and_gates_new_path() {
	root := os.join_path(os.temp_dir(), 'veasel-child-rename-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	workspace := init_subagent_integration_test_repo(root)
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	mut app := new_app(store, os.join_path(root, 'plugins'))
	defer { app.close() }
	parent := store.create_session(SessionInput{ title: 'Parent rename', directory: workspace }) or {
		panic(err)
	}
	parent_operation := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, parent_operation) or { panic(err) }
	run, child_directory := create_completed_implementer_child(mut store, parent, parent_operation,
		workspace, 'integration-rename')
	_ := run_workspace_git_command(child_directory, ['mv', 'README.md', 'MOVED.md']) or { panic(err) }

	response := app.propose_subagent_integration(parent.id, run.id) or { panic(err) }
	assert response.proposals.len == 1
	assert response.proposals[0].path == 'MOVED.md'
	assert response.conflicts.len == 1
	assert response.conflicts[0].path == 'README.md'
	assert response.conflicts[0].reason.contains('deletion requires explicit parent review')
	assert response.proposals[0].status == 'pending'
	assert os.read_file(os.join_path(workspace, 'README.md')) or { panic(err) } == 'base\n'
	assert !os.exists(os.join_path(workspace, 'MOVED.md'))

	_ = store.review_workspace_edit(parent.id, response.proposals[0].id) or { panic(err) }
	edit := store.begin_workspace_edit(parent.id, response.proposals[0].id) or { panic(err) }
	apply_workspace_edit(workspace, edit) or { panic(err) }
	store.finish_workspace_edit(parent.id, response.proposals[0].id, 'applied') or { panic(err) }
	assert os.read_file(os.join_path(workspace, 'README.md')) or { panic(err) } == 'base\n'
	assert os.read_file(os.join_path(workspace, 'MOVED.md')) or { panic(err) } == 'base\n'
}

fn test_cancelled_implementer_conflict_preserves_dirty_worktree_for_review() {
	root := os.join_path(os.temp_dir(), 'veasel-child-cancelled-conflict-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	workspace := init_subagent_integration_test_repo(root)
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	mut app := new_app(store, os.join_path(root, 'plugins'))
	defer { app.close() }
	parent := store.create_session(SessionInput{ title: 'Parent cancelled conflict', directory: workspace }) or {
		panic(err)
	}
	parent_operation := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, parent_operation) or { panic(err) }
	run := store.create_subagent_run(parent.id, parent_operation, 'cancelled-dirty-conflict',
		'implementer', 1, 'Code implementer: update README.md', workspace) or { panic(err) }
	child := store.get_session(run.child_session_id) or { panic(err) }
	_ = store.create_session_operation(child.id, run.child_operation_id) or { panic(err) }
	_ = store.begin_subagent_run(run.id) or { panic(err) }
	child_directory := child.directory
	child_content := 'cancelled child version\n'
	os.write_file(os.join_path(child_directory, 'README.md'), child_content) or { panic(err) }
	os.write_file(os.join_path(child_directory, 'independent.txt'), 'preserve this result\n') or { panic(err) }
	os.write_file(os.join_path(workspace, 'README.md'), 'parent version\n') or { panic(err) }

	requested := app.cancel_subagent_run(parent.id, run.id) or { panic(err) }
	assert requested.status == 'running'
	assert requested.cancel_requested
	finished := store.finish_subagent_run(run.id, 'cancelled', '',
		'Child cancelled after producing partial changes.') or { panic(err) }
	assert finished.status == 'cancelled'
	claimed := store.claim_subagent_outcome(run.id) or { panic(err) }
	assert claimed.outcome_claimed
	app.cleanup_delivered_subagent_workspace(run.id)

	assert os.is_dir(child_directory), 'cancellation cleanup must retain a dirty child worktree'
	retained_run := store.get_subagent_run(run.id) or { panic(err) }
	assert retained_run.workspace_ready
	retained_child := store.get_session(run.child_session_id) or { panic(err) }
	assert os.real_path(retained_child.directory) == os.real_path(child_directory)
	assert os.read_file(os.join_path(workspace, 'README.md')) or { panic(err) } == 'parent version\n'
	assert os.read_file(os.join_path(child_directory, 'README.md')) or { panic(err) } == child_content
	assert os.read_file(os.join_path(child_directory, 'independent.txt')) or { panic(err) } == 'preserve this result\n'

	integration := app.propose_subagent_integration(parent.id, run.id) or { panic(err) }
	assert integration.status == 'cancelled'
	assert integration.conflicts.len == 1
	assert integration.conflicts[0].path == 'README.md'
	assert integration.proposals.len == 1
	assert integration.proposals[0].path == 'independent.txt'
	assert os.read_file(os.join_path(workspace, 'README.md')) or { panic(err) } == 'parent version\n'
	assert !os.exists(os.join_path(workspace, 'independent.txt'))
	assert os.is_dir(child_directory)
}

fn test_child_integration_http_route_returns_reviewable_proposals_without_parent_writes() {
	root := os.join_path(os.temp_dir(), 'veasel-child-integration-http-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	workspace := init_subagent_integration_test_repo(root)
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	mut app := new_app(store, os.join_path(root, 'plugins'))
	defer { app.close() }
	parent := store.create_session(SessionInput{ title: 'Parent HTTP', directory: workspace }) or {
		panic(err)
	}
	parent_operation := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, parent_operation) or { panic(err) }
	run, child_directory := create_completed_implementer_child(mut store, parent, parent_operation,
		workspace, 'integration-http')
	os.write_file(os.join_path(child_directory, 'README.md'), 'HTTP child change\n') or { panic(err) }
	before := os.read_file(os.join_path(workspace, 'README.md')) or { panic(err) }

	mut port_listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	port := port_listener.addr() or { panic(err) }.port() or { panic(err) }
	port_listener.close() or { panic(err) }
	mut api_server_app := &SubagentIntegrationHTTPServer{
		app:          app
		port:         port
		server_ready: chan &veb.Server{cap: 1}
	}
	api_server_thread := spawn run_subagent_integration_http_test_server(mut api_server_app)
	api_server := <-api_server_app.server_ready
	api_server.wait_till_running() or { panic(err) }
	defer {
		api_server.shutdown(timeout: 5 * time.second) or {}
		api_server_thread.wait()
	}
	response := http.fetch(
		url:           'http://127.0.0.1:${port}/v1/sessions/${parent.id}/subagents/${run.id}/integrate'
		header:        integration_test_auth_header()
		method:        .post
		read_timeout:  5 * time.second
		write_timeout: 5 * time.second
	) or { panic(err) }
	assert response.status_code == 200
	integration := json2.decode[SubagentIntegrationResponse](response.body) or { panic(err) }
	assert integration.run_id == run.id
	assert integration.proposals.len == 1
	assert integration.proposals[0].path == 'README.md'
	assert integration.conflicts.len == 0
	assert os.read_file(os.join_path(workspace, 'README.md')) or { panic(err) } == before
	retry := http.fetch(
		url:           'http://127.0.0.1:${port}/v1/sessions/${parent.id}/subagents/${run.id}/integrate'
		header:        integration_test_auth_header()
		method:        .post
		read_timeout:  5 * time.second
		write_timeout: 5 * time.second
	) or { panic(err) }
	assert retry.status_code == 200
	retried := json2.decode[SubagentIntegrationResponse](retry.body) or { panic(err) }
	assert retried.proposals.len == 1
	assert retried.proposals[0].id == integration.proposals[0].id
}

fn init_subagent_integration_test_repo(root string) string {
	repo := os.join_path(root, 'workspace')
	os.mkdir_all(repo) or { panic(err) }
	_ := run_workspace_git_command(repo, ['init', '-b', 'main']) or { panic(err) }
	_ := run_workspace_git_command(repo, ['config', 'user.email', 'veasel@example.com']) or {
		panic(err)
	}
	_ := run_workspace_git_command(repo, ['config', 'user.name', 'Veasel']) or { panic(err) }
	os.write_file(os.join_path(repo, 'README.md'), 'base\n') or { panic(err) }
	_ := run_workspace_git_command(repo, ['add', 'README.md']) or { panic(err) }
	_ := run_workspace_git_command(repo, ['commit', '-m', 'base']) or { panic(err) }
	return repo
}

fn create_completed_implementer_child(mut store Store, parent Session, parent_operation string,
	workspace string, request_id string) (SubagentRun, string) {
	run := store.create_subagent_run(parent.id, parent_operation, request_id, 'implementer', 1,
		'Code implementer: update README.md', workspace) or { panic(err) }
	child := store.get_session(run.child_session_id) or { panic(err) }
	_ = store.create_session_operation(child.id, run.child_operation_id) or { panic(err) }
	_ = store.begin_subagent_run(run.id) or { panic(err) }
	finished := store.finish_subagent_run(run.id, 'completed', 'Child changes ready.', '') or { panic(err) }
	claimed := store.claim_subagent_outcome(finished.id) or { panic(err) }
	return claimed, child.directory
}

fn test_child_integration_never_imports_hook_ci_or_hooks_path_changes() {
	root := os.join_path(os.temp_dir(), 'veasel-child-sensitive-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	workspace := init_subagent_integration_test_repo(root)
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	mut app := new_app(store, os.join_path(root, 'plugins'))
	defer { app.close() }
	parent := store.create_session(SessionInput{ title: 'Parent sensitive', directory: workspace }) or {
		panic(err)
	}
	parent_operation := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, parent_operation) or { panic(err) }
	run, child_directory := create_completed_implementer_child(mut store, parent, parent_operation,
		workspace, 'integration-sensitive')
	_ := run_workspace_git_command(child_directory, ['config', 'core.hooksPath', '.evil-hooks']) or {
		panic(err)
	}
	for relative in ['.github/workflows/ci.yml', '.husky/pre-commit', '.gitattributes', '.envrc',
		'.git-hooks/pre-push', '.evil-hooks/pre-commit'] {
		os.mkdir_all(os.dir(os.join_path(child_directory, relative))) or { panic(err) }
		os.write_file(os.join_path(child_directory, relative), 'echo pwned\n') or { panic(err) }
	}
	os.write_file(os.join_path(child_directory, 'README.md'), 'ordinary change\n') or { panic(err) }
	response := app.propose_subagent_integration(parent.id, run.id) or { panic(err) }
	assert response.proposals.len == 1
	assert response.proposals[0].path == 'README.md'
	// .envrc may be hidden by a developer's global gitignore; it is then never listed, hence never imported.
	assert response.conflicts.len >= 5
	for conflict in response.conflicts {
		assert conflict.reason.contains('manual parent review')
	}
	assert !os.exists(os.join_path(workspace, '.github'))
}

fn test_child_session_shell_commands_run_only_in_the_child_sandbox() {
	$if !linux {
		return
	}
	if !bubblewrap_available() || !prlimit_available() {
		return
	}
	root := os.join_path(os.temp_dir(), 'veasel-child-shell-dispatch-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	workspace := init_subagent_integration_test_repo(root)
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	mut app := new_app(store, os.join_path(root, 'plugins'))
	defer { app.close() }
	parent := store.create_session(SessionInput{ title: 'Parent shell', directory: workspace }) or {
		panic(err)
	}
	parent_operation := uuid.new_v4().str()
	_ = store.create_session_operation(parent.id, parent_operation) or { panic(err) }
	run, child_directory := create_completed_implementer_child(mut store, parent, parent_operation,
		workspace, 'child-shell-dispatch')
	assert (store.child_subagent_run_id(run.child_session_id) or { panic(err) }) == run.id
	assert (store.child_subagent_run_id(parent.id) or { panic(err) }) == ''
	// Even with the operator's unsandboxed opt-in, a child must stay sandboxed.
	prior_mode := os.getenv_opt(shell_sandbox_mode_env)
	prior_opt := os.getenv_opt(shell_sandbox_opt_in_env)
	os.setenv(shell_sandbox_mode_env, 'off', true)
	os.setenv(shell_sandbox_opt_in_env, shell_unsandboxed_opt_in_token, true)
	defer {
		if v := prior_mode {
			os.setenv(shell_sandbox_mode_env, v, true)
		} else {
			os.unsetenv(shell_sandbox_mode_env)
		}
		if v := prior_opt {
			os.setenv(shell_sandbox_opt_in_env, v, true)
		} else {
			os.unsetenv(shell_sandbox_opt_in_env)
		}
	}
	mut ctx := vcontext.background()
	result := app.run_session_shell_command(mut ctx, run.child_session_id, child_directory,
		ShellCommandSummary{
			command:         'printf child > child.txt; (printf bad > ${workspace}/README.md) 2>/dev/null && exit 41; grep -c wlan /proc/net/dev; printf done'
			cwd:             '.'
			timeout_seconds: 5
		}, false)
	assert result.output.contains('done'), result.output
	assert os.read_file(os.join_path(child_directory, 'child.txt')) or { panic(err) } == 'child'
	assert os.read_file(os.join_path(workspace, 'README.md')) or { panic(err) } == 'base\n'
}

// The API rejects every unauthenticated request, so HTTP fixtures install a
// known token and send it like any real client.
fn integration_test_auth_header() http.Header {
	api_auth_state().configure('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', '', true)
	mut header := http.new_header()
	header.set(.authorization, 'Bearer aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
	return header
}
