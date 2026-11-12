module main

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
	assert profile.tool_policy().allows('workspace_read_file')
	assert !profile.tool_policy().allows('workspace_propose_shell_command')
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
