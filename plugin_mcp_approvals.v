module main

const max_pending_plugin_mcp_tool_calls = 20
const max_plugin_mcp_tool_call_history = 50
const max_plugin_mcp_tool_call_argument_bytes = 32_768

pub struct PluginMCPToolCallApproval {
pub:
	id             string
	operation_id   string
	plugin_name    string
	server_name    string
	tool_name      string
	arguments_json string
	status         string
	reviewed_at    string
	created_at     string
	updated_at     string
}

pub struct PluginMCPToolCallSummary {
pub:
	id              string
	operation_id    string
	plugin_name     string
	server_name     string
	tool_name       string
	arguments_bytes int
	status          string
	reviewed_at     string
	created_at      string
	updated_at      string
}

struct AgentPluginMCPCallResponse {
	error string
}
