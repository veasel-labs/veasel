module main

import json2
import net
import net.http
import os
import time
import uuid
import veb

struct AgentTokenBudgetHTTPServer {
	app          &App
	port         int
	server_ready chan &veb.Server
}

pub fn (mut app AgentTokenBudgetHTTPServer) init_server(server &veb.Server) {
	app.server_ready <- server
}

@['/v1/sessions/:id/agent-budget'; get]
pub fn (mut app AgentTokenBudgetHTTPServer) agent_budget(mut ctx Context, id string) veb.Result {
	return app.app.get_session_agent_budget(mut ctx, id)
}

fn run_agent_token_budget_http_test_server(mut app AgentTokenBudgetHTTPServer) {
	veb.run_at[AgentTokenBudgetHTTPServer, Context](mut app,
		host:   '127.0.0.1'
		family: .ip
		port:   app.port
	) or { panic(err) }
}

fn test_session_agent_budget_api_reports_cumulative_tokens_and_cost_provenance() {
	prior_child := os.getenv_opt('VEASEL_AGENT_CHILD_TOKEN_BUDGET')
	prior_parent := os.getenv_opt('VEASEL_AGENT_PARENT_TOKEN_BUDGET')
	defer {
		if value := prior_child {
			os.setenv('VEASEL_AGENT_CHILD_TOKEN_BUDGET', value, true)
		} else {
			os.unsetenv('VEASEL_AGENT_CHILD_TOKEN_BUDGET')
		}
		if value := prior_parent {
			os.setenv('VEASEL_AGENT_PARENT_TOKEN_BUDGET', value, true)
		} else {
			os.unsetenv('VEASEL_AGENT_PARENT_TOKEN_BUDGET')
		}
	}
	os.setenv('VEASEL_AGENT_CHILD_TOKEN_BUDGET', '100', true)
	os.setenv('VEASEL_AGENT_PARENT_TOKEN_BUDGET', '300', true)
	root := os.join_path(os.temp_dir(), 'veasel-agent-budget-api-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	plugin_dir := os.join_path(root, 'plugins')
	os.mkdir_all(plugin_dir) or { panic(err) }
	mut app := new_app(store, plugin_dir)
	defer { app.close() }
	session := store.create_session(SessionInput{
		title:     'Budget API'
		directory: root
	}) or { panic(err) }
	policy := agent_token_budget_policy() or { panic(err) }
	reservation := store.reserve_agent_provider_call(session.id, 12, policy) or { panic(err) }
	store.settle_agent_provider_call(reservation, 'openai', ProviderUsage{
		input_tokens:      7
		output_tokens:     5
		total_tokens:      12
		reported:          true
		reported_cost_usd: f64(0.0042)
	}, 1) or { panic(err) }

	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	port := listener.addr() or { panic(err) }.port() or { panic(err) }
	listener.close() or { panic(err) }
	mut server_app := &AgentTokenBudgetHTTPServer{
		app:          app
		port:         port
		server_ready: chan &veb.Server{cap: 1}
	}
	server_thread := spawn run_agent_token_budget_http_test_server(mut server_app)
	server := <-server_app.server_ready
	server.wait_till_running() or { panic(err) }
	defer {
		server.shutdown(timeout: 5 * time.second) or {}
		server_thread.wait()
	}
	response := http.get('http://127.0.0.1:${port}/v1/sessions/${session.id}/agent-budget') or {
		panic(err)
	}
	assert response.status_code == 200
	summary := json2.decode[AgentTokenBudgetSummary](response.body) or { panic(err) }
	assert summary.root_session_id == session.id
	assert summary.per_child_token_limit == 100
	assert summary.parent_token_limit == 300
	assert summary.reserved_tokens == 0
	assert summary.accounted_tokens == 12
	assert summary.actual_tokens == 12
	assert summary.provider_calls == 1
	assert summary.usage_reported_calls == 1
	assert summary.usage_complete
	assert summary.cost_reported_calls == 1
	assert summary.cost_reported
	assert (summary.reported_cost_usd or { -1.0 }) == f64(0.0042)
}
