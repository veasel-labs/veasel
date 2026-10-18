module main

import context as vcontext
import json2
import time

const max_agent_tool_rounds = 6
const max_agent_tool_calls = 12
const tool_budget_summary_note = 'The tool budget for this turn is spent. Pending tool calls were not run. Reply in text only: what is already done, what is unfinished, and the single next step.'
const max_agent_tool_result_bytes = 1_000_000
const max_agent_tool_argument_bytes = max_workspace_edit_bytes + 4_096

fn agent_context_byte_limit() int {
	return chat_input_byte_limit() + max_agent_tool_result_bytes + max_agent_tool_calls * max_agent_tool_argument_bytes
}

const plugin_mcp_approval_poll_interval = 250 * time.millisecond

// Workspace list/read/search have no durable side effects and may run concurrently
// when a provider returns multiple tools in one round. Skill load/read stay
// sequential so turn-scoped resource grants stay ordered; edits/shell/MCP never
// parallelize.
fn agent_tool_allows_parallel_readonly(name string) bool {
	return name in ['workspace_list_files', 'workspace_read_file', 'workspace_search']
}

fn agent_tool_batch_allows_parallel_readonly(calls []ProviderToolCall) bool {
	if calls.len < 2 {
		return false
	}
	for call in calls {
		if !agent_tool_allows_parallel_readonly(call.function.name) {
			return false
		}
	}
	return true
}

struct ParallelReadonlyToolResult {
	index  int
	result string
}

struct AgentToolNote {
	note string
}

// encode_agent_tool_note encodes a short advisory object (not a hard tool failure).
fn encode_agent_tool_note(message string) string {
	mut buf := []u8{cap: 96 + message.len}
	json2.encode_append(AgentToolNote{
		note: message
	}, mut buf)
	return buf.bytestr()
}

fn workspace_read_path_from_call(call ProviderToolCall) ?string {
	if call.function.name != 'workspace_read_file' {
		return none
	}
	tool_arguments := json2.decode[map[string]json2.Any](call.function.arguments) or { return none }
	path := string_tool_argument(tool_arguments, 'path') or { return none }
	normalized := path.replace('\\', '/').trim_space()
	if normalized.len == 0 {
		return none
	}
	return normalized
}

fn duplicate_workspace_read_note(path string) string {
	return encode_agent_tool_note('Already provided this turn for path "${path}". Reuse the earlier workspace_read_file result; do not request it again.')
}

// execute_parallel_readonly_workspace_tools runs a read-only batch concurrently.
// Duplicate workspace_read_file paths in the same batch or already seen this turn
// receive a short note instead of re-injecting file bytes.
fn execute_parallel_readonly_workspace_tools(app &App, root string, session_id string,
	calls []ProviderToolCall, tool_policy AgentToolPolicy, mut read_paths map[string]bool) []string {
	mut ordered := []string{len: calls.len}
	mut run_indexes := []int{cap: calls.len}
	mut run_calls := []ProviderToolCall{cap: calls.len}
	for i, call in calls {
		if path := workspace_read_path_from_call(call) {
			if read_paths[path] {
				ordered[i] = duplicate_workspace_read_note(path)
				continue
			}
			read_paths[path] = true
		}
		run_indexes << i
		run_calls << call
	}
	if run_calls.len == 0 {
		return ordered
	}
	results_ch := chan ParallelReadonlyToolResult{cap: run_calls.len}
	for i, call in run_calls {
		spawn execute_parallel_readonly_workspace_tool_worker(app, root, session_id, tool_policy,
			i, call, results_ch)
	}
	mut run_results := []string{len: run_calls.len}
	for _ in 0 .. run_calls.len {
		item := <-results_ch
		run_results[item.index] = item.result
	}
	for i, call_index in run_indexes {
		ordered[call_index] = run_results[i]
	}
	return ordered
}

fn execute_parallel_readonly_workspace_tool_worker(app &App, root string, session_id string,
	tool_policy AgentToolPolicy, index int, call ProviderToolCall, results_ch chan ParallelReadonlyToolResult) {
	mut result := ''
	if !tool_policy.allows(call.function.name) {
		result = encode_agent_tool_error('Tool is not available under the active Agent Skill tool restrictions.')
	} else {
		result = sanitize_agent_tool_result(execute_workspace_agent_tool(app, root, session_id,
			call))
	}
	results_ch <- ParallelReadonlyToolResult{
		index:  index
		result: result
	}
}

struct AgentToolError {
	error string
}

// encode_agent_tool_error encodes a small error object into a right-sized buffer.
fn encode_agent_tool_error(message string) string {
	mut buf := []u8{cap: 96 + message.len}
	json2.encode_append(AgentToolError{
		error: message
	}, mut buf)
	return buf.bytestr()
}

struct AgentWorkspaceEditResult {
	id   string
	path string
	note string
}

fn workspace_agent_tools() []AgentToolDefinition {
	return [
		AgentToolDefinition{
			name:        'workspace_list_files'
			description: 'List up to 500 regular files in the current workspace. Common generated and dependency directories and symbolic links are skipped.'
			parameters:  ToolParameters{
				properties: map[string]ToolParameter{}
				required:   []string{}
			}
		},
		AgentToolDefinition{
			name:        'workspace_read_file'
			description: 'Read one UTF-8 text file inside the current workspace. Files are limited to 512000 bytes.'
			parameters:  ToolParameters{
				properties: {
					'path': ToolParameter{
						type:        'string'
						description: 'Relative file path inside the workspace.'
					}
				}
				required:   ['path']
			}
		},
		AgentToolDefinition{
			name:        'workspace_search'
			description: 'Search for a literal, case-sensitive text string in bounded workspace files.'
			parameters:  ToolParameters{
				properties: {
					'query': ToolParameter{
						type:        'string'
						description: 'Literal text to find; maximum 256 UTF-8 bytes.'
					}
				}
				required:   ['query']
			}
		},
		AgentToolDefinition{
			name:        'workspace_propose_file_edit'
			description: 'Propose a change to one UTF-8 file in the current workspace. This never writes the file. The user must inspect and explicitly approve the stored diff before it is applied.'
			parameters:  ToolParameters{
				properties: {
					'path':    ToolParameter{
						type:        'string'
						description: 'Relative path to an existing file or a new file whose parent directory already exists.'
					}
					'content': ToolParameter{
						type:        'string'
						description: 'Complete proposed UTF-8 text for this one file, at most 512000 bytes.'
					}
				}
				required:   ['path', 'content']
			}
		},
		AgentToolDefinition{
			name:        'workspace_propose_shell_command'
			description: 'Propose one single-line shell command for the user to inspect and explicitly approve. This tool never executes commands. Execution uses /bin/sh on POSIX or COMSPEC on Windows with the server OS user identity. On Linux, when bubblewrap (bwrap) is available and VEASEL_SHELL_SANDBOX is not off, approved commands run in a Bubblewrap sandbox (read-only host, writable workspace, network isolated by default). On macOS, when /usr/bin/sandbox-exec is available and VEASEL_SHELL_SANDBOX is not off, approved commands run under Seatbelt (writable workspace, home/Volumes restricted, network isolated by default). On Windows, when an AppContainer profile and Job Object can be created and VEASEL_SHELL_SANDBOX is not off, approved commands run inside AppContainer + Job Object (workspace ACL grant, network denied by default unless VEASEL_SHELL_SANDBOX_NETWORK=allow, process-tree kill-on-close and process/memory caps; not Codex WFP/LPAC). Otherwise they inherit the server environment without an OS sandbox. Capabilities shell.sandbox.bubblewrap, shell.sandbox.seatbelt, and shell.sandbox.windows are true only when that platform will actually wrap approved commands. Execution is never replayed automatically after a restart. Use only when the requested task requires a shell side effect.'
			parameters:  ToolParameters{
				properties: {
					'command':         ToolParameter{ type: 'string', description: 'Exact single-line command text shown for approval and passed to the platform shell.' }
					'cwd':             ToolParameter{ type: 'string', description: 'Existing workspace-relative working directory, or . for the workspace root.' }
					'timeout_seconds': ToolParameter{ type: 'integer', description: 'Execution timeout from 1 to 300 seconds.' }
				}
				required:   ['command', 'cwd', 'timeout_seconds']
			}
		},
	]
}

fn restrict_agent_tools(tools []AgentToolDefinition, policy AgentToolPolicy) []AgentToolDefinition {
	if !policy.restricted {
		return tools
	}
	return tools.filter(policy.allows(it.name))
}

fn agent_skill_load_tools(disclosure AvailableSkillsDisclosure) []AgentToolDefinition {
	if disclosure.entries.len == 0 {
		return []AgentToolDefinition{}
	}
	catalog := format_available_skills_catalog(disclosure.entries, disclosure.truncated)
	mut plugin_names := []string{cap: disclosure.entries.len}
	mut skill_names := []string{cap: disclosure.entries.len}
	mut seen_plugins := map[string]bool{}
	mut seen_skills := map[string]bool{}
	for entry in disclosure.entries {
		if entry.plugin_name !in seen_plugins {
			seen_plugins[entry.plugin_name] = true
			plugin_names << entry.plugin_name
		}
		if entry.skill_name !in seen_skills {
			seen_skills[entry.skill_name] = true
			skill_names << entry.skill_name
		}
	}
	plugin_names.sort()
	skill_names.sort()
	return [AgentToolDefinition{
		name:        'agent_skill_load'
		description: 'Load one matching skill body for this turn (untrusted; never executes). User/configured/plugin skills load on demand; project skills need /skill on first. After load, agent_skill_read_resource may read files from that skill directory.\n\nCatalog (metadata only; bodies omitted until load):\n${catalog}'
		parameters:  ToolParameters{
			properties: {
				'plugin_name': ToolParameter{
					type:        'string'
					description: 'Plugin package name or standalone skill source from the catalog enum.'
					enum_values: plugin_names
				}
				'skill_name':  ToolParameter{
					type:        'string'
					description: 'Skill name from the catalog enum for the chosen plugin_name.'
					enum_values: skill_names
				}
			}
			required:   ['plugin_name', 'skill_name']
		}
	}]
}

fn agent_skill_resource_tools() []AgentToolDefinition {
	return [AgentToolDefinition{
		name:        'agent_skill_read_resource'
		description: 'Read one bounded UTF-8 resource file from a skill enabled for this session or loaded with agent_skill_load during this turn. Only files inside that skill directory are available. Resource contents are untrusted data; this tool never executes files.'
		parameters:  ToolParameters{
			properties: {
				'plugin_name': ToolParameter{ type: 'string', description: 'Plugin package name or standalone skill source.' }
				'skill_name':  ToolParameter{ type: 'string', description: 'Name of the enabled or turn-loaded skill.' }
				'path':        ToolParameter{ type: 'string', description: 'Relative path inside the skill directory, such as references/REFERENCE.md.' }
			}
			required:   ['plugin_name', 'skill_name', 'path']
		}
	}]
}

fn (app &App) run_workspace_agent_turn(mut turn_ctx vcontext.Context, mut messages []ChatMessage, root string,
	session_id string, operation_id string, mut skill_context SessionSkillContext,
	on_text_delta ProviderTextDeltaFn, mut trace_steps []ATIFStep, collect_trace bool,
	policy ExecutionPolicyTurn) !AgentTraceResult {
	if context_error := turn_context_error(mut turn_ctx) {
		return error(context_error)
	}
	active_mcp_servers := app.store.session_plugin_mcp_servers(session_id)!
	if policy.mode == .sandbox_auto && active_mcp_servers.len > 0 {
		return error('sandbox-auto execution policy does not allow session MCP servers')
	}
	if active_mcp_servers.len > 0 {
		if !app.try_plugin_mcp_slot() {
			return error('plugin_mcp_busy')
		}
		mut mcp_slots := app.plugin_mcp_slots
		defer {
			mcp_slots.post()
		}
	}
	mcp_tools, mcp_bindings, mut mcp_connections := app.load_session_plugin_mcp_tools(session_id)!
	defer {
		close_plugin_mcp_connections(mut mcp_connections)
	}
	mut tools := workspace_agent_tools()
	tools << agent_skill_load_tools(app.available_skills_for_turn(project_directory_for_skills(root),
		session_id))
	tools << agent_skill_resource_tools()
	tools << mcp_tools
	tools = restrict_agent_tools(tools, skill_context.tool_policy)
	mut tool_calls := 0
	mut result_bytes := 0
	mut seen_tool_call_ids := map[string]bool{}
	mut read_paths := map[string]bool{}
	if collect_trace {
		for message in messages {
			source := match message.role {
				'system' { 'system' }
				'user' { 'user' }
				'assistant' { 'agent' }
				else { continue }
			}
			trace_steps << ATIFStep{
				step_id: trace_steps.len + 1
				source:  source
				message: message.content
			}
		}
	}
	mut trace_usage := ProviderUsage{}
	for round in 0 .. max_agent_tool_rounds {
		if context_error := turn_context_error(mut turn_ctx) {
			return error(context_error)
		}
		app.apply_session_compaction_if_due(mut turn_ctx, mut messages, session_id, operation_id)!
		if agent_context_bytes(messages) > agent_context_byte_limit() {
			return error('agent context size limit reached')
		}
		output := app.complete_agent_with_provider_limit(mut turn_ctx, messages, tools, on_text_delta)!
		if output.usage.reported {
			trace_usage = add_provider_usage(trace_usage, output.usage)
		}
		if output.tool_calls.len == 0 {
			if output.content.trim_space().len == 0 {
				return error('model returned no final response')
			}
			if collect_trace {
				trace_steps << ATIFStep{
					step_id:    trace_steps.len + 1
					source:     'agent'
					model_name: output.model
					message:    output.content
				}
			}
			return AgentTraceResult{
				output: output
				steps:  trace_steps
				usage:  trace_usage
			}
		}
		if tool_calls + output.tool_calls.len > max_agent_tool_calls {
			return error('agent tool call limit reached')
		}
		if round == max_agent_tool_rounds - 1 {
			return app.finish_with_tool_budget_summary(mut turn_ctx, messages, output, on_text_delta,
				mut trace_steps, mut trace_usage, collect_trace)
		}
		for call in output.tool_calls {
			if context_error := turn_context_error(mut turn_ctx) {
				return error(context_error)
			}
			if call.type != 'function' || call.id.trim_space().len == 0 || call.id.len > 200
				|| call.function.name.len == 0 || call.function.name.len > 100
				|| call.function.arguments.len > max_agent_tool_argument_bytes {
				return error('provider returned an invalid or oversized tool call')
			}
			if seen_tool_call_ids[call.id] {
				return error('provider returned a duplicate tool call id')
			}
			seen_tool_call_ids[call.id] = true
		}
		mut trace_tool_calls := []ATIFToolCall{}
		if collect_trace {
			for call in output.tool_calls {
				trace_tool_calls << atif_tool_call(call)!
			}
			trace_steps << ATIFStep{
				step_id:    trace_steps.len + 1
				source:     'agent'
				model_name: output.model
				message:    output.content
				tool_calls: trace_tool_calls
			}
		}
		messages << ChatMessage{
			role:             'assistant'
			content:          output.content
			tool_calls:       output.tool_calls
			provider_context: output.provider_context
		}
		tool_calls += output.tool_calls.len
		mut tool_results := []string{cap: output.tool_calls.len}
		if agent_tool_batch_allows_parallel_readonly(output.tool_calls) {
			if context_error := turn_context_error(mut turn_ctx) {
				return error(context_error)
			}
			tool_results = execute_parallel_readonly_workspace_tools(app, root, session_id,
				output.tool_calls, skill_context.tool_policy, mut read_paths)
			if context_error := turn_context_error(mut turn_ctx) {
				return error(context_error)
			}
		} else {
			for call in output.tool_calls {
				if context_error := turn_context_error(mut turn_ctx) {
					return error(context_error)
				}
				if path := workspace_read_path_from_call(call) {
					if read_paths[path] {
						tool_results << duplicate_workspace_read_note(path)
						continue
					}
				}
				result := sanitize_agent_tool_result(execute_agent_tool_if_allowed(app, mut turn_ctx,
					root, session_id, operation_id, call, mut skill_context, mcp_bindings, mut mcp_connections,
					policy)!)
				if path := workspace_read_path_from_call(call) {
					read_paths[path] = true
				}
				tool_results << result
			}
		}
		mut trace_observations := []ATIFObservationResult{}
		for i, call in output.tool_calls {
			result := tool_results[i]
			result_bytes += result.len
			if result_bytes > max_agent_tool_result_bytes {
				return error('agent tool result limit reached')
			}
			if collect_trace {
				trace_observations << ATIFObservationResult{
					source_call_id: call.id
					content:        result
				}
			}
			messages << ChatMessage{
				role:                  'tool'
				name:                  call.function.name
				tool_call_id:          call.id
				provider_tool_call_id: call.provider_call_id
				content:               result
			}
		}
		if collect_trace {
			trace_steps[trace_steps.len - 1].observation = ATIFObservation{
				results: trace_observations
			}
		}
		// Text from the next model round must not stick to this round's
		// narration. The model-visible message stays unchanged.
		boundary := tool_round_text_boundary(output.content)
		if boundary.len > 0 {
			on_text_delta(boundary)!
		}
	}
	return error('agent tool round limit reached')
}

fn tool_budget_summary_note_for(calls []ProviderToolCall) string {
	mut names := []string{cap: calls.len}
	mut seen := map[string]bool{}
	for call in calls {
		name := call.function.name.trim_space()
		if name.len == 0 || seen[name] {
			continue
		}
		seen[name] = true
		names << name
		if names.len == 8 {
			break
		}
	}
	if names.len == 0 {
		return tool_budget_summary_note
	}
	return tool_budget_summary_note + ' Not run: ' + names.join(', ') + '.'
}

fn messages_for_tool_budget_summary(messages []ChatMessage, calls []ProviderToolCall) []ChatMessage {
	note := tool_budget_summary_note_for(calls)
	mut summary_messages := []ChatMessage{cap: messages.len + 1}
	if messages.len > 0 && messages[0].role == 'system' {
		summary_messages << ChatMessage{
			role:    'system'
			content: messages[0].content + '\n\n' + note
		}
		for index in 1 .. messages.len {
			summary_messages << messages[index]
		}
		return summary_messages
	}
	summary_messages << ChatMessage{
		role:    'system'
		content: note
	}
	for message in messages {
		summary_messages << message
	}
	return summary_messages
}

fn (app &App) finish_with_tool_budget_summary(mut turn_ctx vcontext.Context, messages []ChatMessage,
	blocked CompletionOutput, on_text_delta ProviderTextDeltaFn, mut trace_steps []ATIFStep,
	mut trace_usage ProviderUsage, collect_trace bool) !AgentTraceResult {
	summary_messages := messages_for_tool_budget_summary(messages, blocked.tool_calls)
	if agent_context_bytes(summary_messages) > agent_context_byte_limit() {
		return error('agent tool round limit reached')
	}
	boundary := tool_round_text_boundary(blocked.content)
	if boundary.len > 0 {
		on_text_delta(boundary)!
	}
	summary := app.complete_agent_with_provider_limit(mut turn_ctx, summary_messages, [],
		on_text_delta)!
	if summary.usage.reported {
		trace_usage = add_provider_usage(trace_usage, summary.usage)
	}
	if summary.content.trim_space().len == 0 {
		return error('agent tool round limit reached')
	}
	if collect_trace && blocked.content.trim_space().len > 0 {
		trace_steps << ATIFStep{
			step_id:    trace_steps.len + 1
			source:     'agent'
			model_name: blocked.model
			message:    blocked.content
		}
	}
	if collect_trace {
		trace_steps << ATIFStep{
			step_id:    trace_steps.len + 1
			source:     'agent'
			model_name: summary.model
			message:    summary.content
		}
	}
	return AgentTraceResult{
		output: summary
		steps:  trace_steps
		usage:  trace_usage
	}
}

fn tool_round_text_boundary(content string) string {
	if content.len == 0 || content.ends_with('\n') {
		return ''
	}
	return '\n'
}

// sanitize_agent_tool_result keeps untrusted tool output out of provider history
// when it contains binary-unsafe NUL bytes, while letting the turn continue.
fn sanitize_agent_tool_result(result string) string {
	if result.contains('\0') {
		return 'tool result rejected: contained a NUL byte'
	}
	return result
}

fn execute_agent_tool_if_allowed(app &App, mut turn_ctx vcontext.Context, root string,
	session_id string, operation_id string, call ProviderToolCall,
	mut skill_context SessionSkillContext, mcp_bindings map[string]PluginMCPToolBinding,
	mut mcp_connections []PluginMCPConnection, policy ExecutionPolicyTurn) !string {
	if !skill_context.tool_policy.allows(call.function.name) {
		return encode_agent_tool_error('Tool is not available under the active Agent Skill tool restrictions.')
	}
	if binding := mcp_bindings[call.function.name] {
		decision := decide_execution_permission(policy.mode, 'mcp', policy.interactive,
			fail_closed_shell_sandbox_ready())
		match decision {
			.deny {
				return encode_agent_tool_error('MCP tools are denied by execution policy `${execution_policy_mode_label(policy.mode)}`.')
			}
			.allow {
				return encode_agent_tool_error('MCP tools cannot auto-apply under the current policy; they remain approval-gated.')
			}
			.ask {
				return app.execute_plugin_mcp_tool_with_approval(mut turn_ctx, session_id,
					operation_id, binding, call.function.arguments, mut mcp_connections)!
			}
		}
	}
	tool_class := execution_tool_class(call.function.name)
	if call.function.name == 'agent_skill_load' {
		mut skill_store := app.store
		session_skills := skill_store.session_plugin_skills(session_id) or { []SessionPluginSkill{} }
		result, granted, access := execute_agent_skill_load(app.plugin_directory, project_directory_for_skills(root),
			call, session_skills)
		if granted {
			already := skill_context.resource_access.any(it.plugin_name == access.plugin_name
				&& it.skill_name == access.skill_name)
			if !already {
				skill_context.resource_access << access
			}
		}
		return result
	}
	if call.function.name == 'agent_skill_read_resource' {
		return execute_agent_skill_resource(skill_context.resource_access, call)
	}
	if tool_class in ['edit', 'shell'] {
		decision := decide_execution_permission(policy.mode, tool_class, policy.interactive,
			fail_closed_shell_sandbox_ready())
		match decision {
			.allow {
				return execute_autonomous_workspace_agent_tool(app, root, session_id, call)
			}
			.deny {
				reason := if tool_class == 'shell' && policy.mode == .sandbox_auto
					&& !fail_closed_shell_sandbox_ready() {
					'Shell auto-apply requires a fail-closed OS sandbox (Bubblewrap, Seatbelt, or AppContainer+Job); none is available.'
				} else if !policy.interactive {
					'Non-interactive turns deny `${call.function.name}` under execution policy `${execution_policy_mode_label(policy.mode)}` (ask maps to deny).'
				} else {
					'`${call.function.name}` is denied by execution policy `${execution_policy_mode_label(policy.mode)}`.'
				}
				return encode_agent_tool_error(reason)
			}
			.ask {
				// Fall through to durable proposal/approval path.
			}
		}
	}
	return execute_workspace_agent_tool(app, root, session_id, call)
}

fn execute_autonomous_workspace_agent_tool(app &App, root string, session_id string,
	call ProviderToolCall) string {
	if call.function.name == 'workspace_propose_file_edit' {
		tool_arguments := json2.decode[map[string]json2.Any](call.function.arguments) or {
			return encode_agent_tool_error('Tool arguments must be a JSON object.')
		}
		path := string_tool_argument(tool_arguments, 'path') or {
			return encode_agent_tool_error('A relative file path is required.')
		}
		content := string_tool_argument(tool_arguments, 'content') or {
			return encode_agent_tool_error('Proposed UTF-8 file content is required.')
		}
		if tool_arguments.len != 2 {
			return encode_agent_tool_error('Unexpected tool argument.')
		}
		draft := prepare_workspace_edit(root, path, content) or {
			return encode_agent_tool_error('The workspace edit is invalid or unavailable: ${err.msg()}')
		}
		mut store := app.store
		proposal := store.create_workspace_edit(session_id, draft) or {
			return encode_agent_tool_error('The workspace edit could not be saved.')
		}
		store.review_workspace_edit(session_id, proposal.id) or {
			return encode_agent_tool_error('The workspace edit could not be recorded for application.')
		}
		edit := store.begin_workspace_edit(session_id, proposal.id) or {
			return encode_agent_tool_error('The workspace edit could not begin safely.')
		}
		apply_workspace_edit(root, edit) or {
			message := err.msg()
			status := if message.contains('changed after review') || message.contains('invalid segment')
				|| message.contains('symbolic link') || message.contains('escapes') {
				'conflict'
			} else {
				'interrupted'
			}
			store.finish_workspace_edit(session_id, proposal.id, status) or {}
			return encode_agent_tool_error('The workspace edit could not be applied safely: ${message}')
		}
		store.finish_workspace_edit(session_id, proposal.id, 'applied') or {
			return encode_agent_tool_error('The edit was applied but its outcome could not be recorded; inspect the workspace.')
		}
		return json2.encode[AgentWorkspaceEditResult](AgentWorkspaceEditResult{
			id:   proposal.id
			path: proposal.path
			note: 'Applied by graduated execution policy (auto-edit or sandbox-auto).'
		})
	}
	if call.function.name == 'workspace_propose_shell_command' {
		if !app.begin_shell_operation() {
			return encode_agent_tool_error('Veasel is shutting down and cannot start a command.')
		}
		defer {
			app.finish_shell_operation()
		}
		mut slots := app.shell_command_slots
		if !slots.try_wait() {
			return encode_agent_tool_error('Shell execution capacity is full; retry after an active command finishes.')
		}
		defer {
			slots.post()
		}
		draft := parse_shell_tool_arguments(call.function.arguments, root) or {
			return encode_agent_tool_error('The shell command is invalid: ${err.msg()}')
		}
		mut store := app.store
		proposal := store.create_shell_command(session_id, draft) or {
			return encode_agent_tool_error('The shell command could not be recorded.')
		}
		store.review_shell_command(session_id, proposal.id) or {
			return encode_agent_tool_error('The shell command could not be recorded for execution.')
		}
		approved := store.begin_shell_command(session_id, proposal.id) or {
			return encode_agent_tool_error('The shell command could not begin safely.')
		}
		result := run_approved_shell_command_with_policy(root, approved, true)
		store.finish_shell_command(session_id, proposal.id, result) or {
			return encode_agent_tool_error('The command finished but its result could not be recorded.')
		}
		return json2.encode(ShellCommandSummary{
			id:              proposal.id
			command:         proposal.command
			cwd:             proposal.cwd
			timeout_seconds: proposal.timeout_seconds
			status:          result.status
			exit_code:       result.exit_code
			output:          result.output
			created_at:      proposal.created_at
			updated_at:      proposal.updated_at
			sandbox:         shell_review_sandbox_preview()
		})
	}
	return encode_agent_tool_error('Tool is not available under autonomous benchmark policy.')
}

fn (app &App) execute_plugin_mcp_tool_with_approval(mut turn_ctx vcontext.Context,
	session_id string, operation_id string, binding PluginMCPToolBinding, arguments string,
	mut mcp_connections []PluginMCPConnection) !string {
	if binding.connection_index < 0 || binding.connection_index >= mcp_connections.len {
		return '{"error":"MCP server connection is unavailable."}'
	}
	if arguments.len > max_plugin_mcp_tool_call_argument_bytes {
		return '{"error":"MCP tool arguments exceed the review size limit."}'
	}
	_ := json2.decode[map[string]json2.Any](arguments) or {
		return '{"error":"MCP tool arguments must be a JSON object."}'
	}
	call := app.store.create_plugin_mcp_tool_call(session_id, operation_id, binding.plugin_name,
		binding.server_name, binding.native_name, arguments) or {
		if err.msg() == 'pending MCP tool call limit reached' {
			return '{"error":"Too many MCP tool calls are awaiting user review."}'
		}
		return err
	}
	for {
		if context_error := turn_context_error(mut turn_ctx) {
			mut store := app.store
			store.cancel_plugin_mcp_tool_call(session_id, call.id) or {}
			return error(context_error)
		}
		current := app.store.get_plugin_mcp_tool_call(session_id, call.id)!
		match current.status {
			'pending' {
				time.sleep(plugin_mcp_approval_poll_interval)
				continue
			}
			'rejected' {
				return encode_agent_tool_error('The user rejected this MCP tool call. Do not retry it unless the user asks.')
			}
			'approved' {
				if context_error := turn_context_error(mut turn_ctx) {
					mut store := app.store
					store.cancel_plugin_mcp_tool_call(session_id, call.id) or {}
					return error(context_error)
				}
				mut store := app.store
				store.begin_plugin_mcp_tool_call(session_id, call.id)!
				cancel_done := chan int{cap: 1}
				if binding.connection_index >= 0 && binding.connection_index < mcp_connections.len {
					stdio := mcp_connections[binding.connection_index].stdio_transport
					http_transport := mcp_connections[binding.connection_index].http_transport
					if !isnil(stdio) || !isnil(http_transport) {
						spawn watch_plugin_mcp_cancel(mut turn_ctx, stdio, http_transport,
							cancel_done)
					} else {
						cancel_done <- 1
					}
				} else {
					cancel_done <- 1
				}
				result := execute_plugin_mcp_tool(mut mcp_connections, binding, arguments)
				_ = cancel_done.try_push(1) // ignore .not_ready/.closed; watcher may have exited
				if context_error := turn_context_error(mut turn_ctx) {
					if context_error == 'cancelled' {
						store.finish_plugin_mcp_tool_call(session_id, call.id, 'cancelled') or {}
						return error(context_error)
					}
				}
				status := if plugin_mcp_tool_result_failed(result) { 'failed' } else { 'completed' }
				store.finish_plugin_mcp_tool_call(session_id, call.id, status)!
				return result
			}
			else {
				return error('MCP tool call entered an unexpected state: ${current.status}')
			}
		}
	}
}

fn plugin_mcp_tool_result_failed(result string) bool {
	if result.starts_with('{"error":') {
		return true
	}
	fields := json2.decode[map[string]json2.Any](result) or { return false }
	if error_value := fields['isError'] {
		return error_value is bool && error_value as bool
	}
	return false
}

fn execute_agent_skill_load(plugin_directory string, project_directory string, call ProviderToolCall,
	session_skills []SessionPluginSkill) (string, bool, AgentSkillResourceAccess) {
	empty := AgentSkillResourceAccess{}
	tool_arguments := json2.decode[map[string]json2.Any](call.function.arguments) or {
		return encode_agent_tool_error('Tool arguments must be a JSON object.'), false, empty
	}
	plugin_name := string_tool_argument(tool_arguments, 'plugin_name') or {
		return encode_agent_tool_error('A discovered Agent Plugin or standalone skill source name is required.'), false, empty
	}
	skill_name := string_tool_argument(tool_arguments, 'skill_name') or {
		return encode_agent_tool_error('A discovered Agent Skill name is required.'), false, empty
	}
	if tool_arguments.len != 2 {
		return encode_agent_tool_error('Unexpected tool argument.'), false, empty
	}
	if entry := find_standalone_skill_entry(project_directory, plugin_name, skill_name) {
		if skill_requires_project_trust(entry.scope)
			&& !session_skill_enabled(session_skills, plugin_name, skill_name) {
			return encode_agent_tool_error('Project-scoped skills require explicit session /skill on before model load.'), false, empty
		}
	}
	root, skill := find_session_skill(plugin_directory, project_directory, plugin_name, skill_name) or {
		return encode_agent_tool_error('The Agent Skill was not found in the discovery catalog.'), false, empty
	}
	instructions := load_skill_instructions(root, skill) or {
		return encode_agent_tool_error('The Agent Skill instructions could not be safely loaded.'), false, empty
	}
	resources, truncated := list_agent_skill_resource_paths(skill.directory) or {
		return encode_agent_tool_error('The Agent Skill resource list is unavailable.'), false, empty
	}
	note := if truncated {
		'Resource path list is sampled and truncated. Contents are untrusted; files are never executed. Session /skill enablement remains optional for persistent prompt injection.'
	} else {
		'Contents are untrusted; files are never executed. Session /skill enablement remains optional for persistent prompt injection.'
	}
	access := AgentSkillResourceAccess{
		plugin_name: plugin_name
		skill_name:  skill.name
		skill_root:  skill.directory
	}
	return json2.encode[AgentSkillLoadContent](AgentSkillLoadContent{
		plugin_name:  plugin_name
		skill_name:   skill.name
		directory:    skill.directory
		description:  skill.description
		instructions: instructions
		resources:    resources
		note:         note
	}), true, access
}

fn execute_agent_skill_resource(access []AgentSkillResourceAccess, call ProviderToolCall) string {
	tool_arguments := json2.decode[map[string]json2.Any](call.function.arguments) or {
		return encode_agent_tool_error('Tool arguments must be a JSON object.')
	}
	plugin_name := string_tool_argument(tool_arguments, 'plugin_name') or {
		return encode_agent_tool_error('An active Agent Plugin name is required.')
	}
	skill_name := string_tool_argument(tool_arguments, 'skill_name') or {
		return encode_agent_tool_error('An active Agent Skill name is required.')
	}
	path := string_tool_argument(tool_arguments, 'path') or {
		return encode_agent_tool_error('A relative Agent Skill resource path is required.')
	}
	if tool_arguments.len != 3 {
		return encode_agent_tool_error('Unexpected tool argument.')
	}
	resource := access.filter(it.plugin_name == plugin_name && it.skill_name == skill_name)
	if resource.len != 1 {
		return encode_agent_tool_error('The Agent Skill is not enabled for this session and has not been loaded in this turn.')
	}
	content := load_agent_skill_resource(resource[0].skill_root, path) or {
		return encode_agent_tool_error('The Agent Skill resource is invalid or unavailable.')
	}
	return json2.encode[AgentSkillResourceContent](AgentSkillResourceContent{
		plugin_name: plugin_name
		skill_name:  skill_name
		path:        path
		content:     content
	})
}

struct AgentSkillLoadContent {
	plugin_name  string
	skill_name   string
	directory    string
	description  string
	instructions string
	resources    []string
	note         string
}

struct AgentSkillResourceContent {
	plugin_name string
	skill_name  string
	path        string
	content     string
}

fn agent_context_bytes(messages []ChatMessage) int {
	mut total := 0
	for message in messages {
		total += message.content.len
		total += message.name.len + message.tool_call_id.len + message.provider_tool_call_id.len
		for context_item in message.provider_context {
			total += context_item.len
		}
		for call in message.tool_calls {
			total += call.function.arguments.len
			total += call.id.len + call.provider_call_id.len + call.provider_signature.len
			total += call.function.name.len
		}
	}
	return total
}

// apply_session_compaction_if_due shrinks the in-flight provider request when
// measured UTF-8 payload pressure rises. Durable chat rows stay intact; a
// session.compaction event records measured before/after sizes. Optional native
// or LLM summarizers are selected by VEASEL_SESSION_COMPACTION_SUMMARIZER and
// fall back to extractive compaction when unavailable, empty, or when they grow
// measured UTF-8 context.
fn (app &App) apply_session_compaction_if_due(mut turn_ctx vcontext.Context, mut messages []ChatMessage,
	session_id string, operation_id string) ! {
	mode := session_compaction_summarizer_mode()
	result := match mode {
		'native' {
			compact_session_messages_with_summarizer(messages, 'native', native_session_compaction_summarizer)
		}
		'llm' {
			app.compact_session_messages_with_llm_summarizer(mut turn_ctx, messages)
		}
		else {
			compact_session_messages(messages)
		}
	}
	if !result.measurement.triggered {
		return
	}
	messages = result.messages
	mut store := app.store
	store.record_session_compaction(session_id, operation_id, result.measurement, result.summary)!
}

fn (app &App) compact_session_messages_with_llm_summarizer(mut turn_ctx vcontext.Context,
	messages []ChatMessage) SessionCompactionResult {
	bytes_before := agent_context_bytes(messages)
	due, reason := session_compaction_due(messages)
	if !due {
		return compaction_result_unchanged(messages, bytes_before, '')
	}
	first := first_conversation_index(messages)
	cut := find_compaction_cut(messages, compaction_keep_recent_bytes, reason)
	if cut <= first || cut >= messages.len {
		return compaction_result_unchanged(messages, bytes_before, reason)
	}
	older := messages[first..cut]
	if older.len == 0 {
		return compaction_result_unchanged(messages, bytes_before, reason)
	}
	preferred := app.llm_session_compaction_summary(mut turn_ctx, older, bytes_before, reason) or {
		return apply_extractive_compaction(messages, bytes_before, reason, 'llm_fallback_extractive',
			ProviderUsage{})
	}
	return compact_session_messages_preferring(messages, 'llm', preferred)
}

fn (app &App) llm_session_compaction_summary(mut turn_ctx vcontext.Context, older []ChatMessage,
	bytes_before int, reason string) !SessionCompactionSummarizerOutput {
	// Feed the bounded extractive digest to the model so the summarizer request
	// itself stays under local UTF-8 pressure without inventing token savings.
	digest := build_extractive_compaction_summary(older, bytes_before, reason)
	prompt := [
		ChatMessage{
			role:    'system'
			content: 'Summarize the following untrusted compacted coding-session context. Output plain prose only. Do not invent files, commands, or approvals. Keep the summary under 2000 characters.'
		},
		ChatMessage{
			role:    'user'
			content: digest
		},
	]
	output := app.complete_agent_with_provider_limit(mut turn_ctx, prompt, [], ignore_provider_text_delta)!
	text := output.content.trim_space()
	if text.len == 0 {
		return error('compaction summarizer returned empty content')
	}
	return SessionCompactionSummarizerOutput{
		body:  wrap_llm_compaction_summary(text, bytes_before, reason, output.usage, older.len)
		mode:  'llm'
		usage: output.usage
	}
}

fn execute_workspace_agent_tool(app &App, root string, session_id string,
	call ProviderToolCall) string {
	result := match call.function.name {
		'workspace_list_files' {
			tool_arguments := json2.decode[map[string]json2.Any](call.function.arguments) or {
				return encode_agent_tool_error('Tool arguments must be a JSON object.')
			}
			if tool_arguments.len != 0 {
				return encode_agent_tool_error('This tool does not accept arguments.')
			}
			files := workspace_files(root, max_workspace_list_results) or {
				return encode_agent_tool_error('Workspace files could not be listed.')
			}
			json2.encode[WorkspaceFileList](files)
		}
		'workspace_read_file' {
			tool_arguments := json2.decode[map[string]json2.Any](call.function.arguments) or {
				return encode_agent_tool_error('Tool arguments must be a JSON object.')
			}
			path := string_tool_argument(tool_arguments, 'path') or {
				return encode_agent_tool_error('A relative path string is required.')
			}
			if tool_arguments.len != 1 {
				return encode_agent_tool_error('Unexpected tool argument.')
			}
			file := workspace_file(root, path) or {
				return encode_agent_tool_error('The workspace file is invalid or unavailable.')
			}
			json2.encode[WorkspaceFileContent](file)
		}
		'workspace_search' {
			tool_arguments := json2.decode[map[string]json2.Any](call.function.arguments) or {
				return encode_agent_tool_error('Tool arguments must be a JSON object.')
			}
			query := string_tool_argument(tool_arguments, 'query') or {
				return encode_agent_tool_error('A search query string is required.')
			}
			if tool_arguments.len != 1 {
				return encode_agent_tool_error('Unexpected tool argument.')
			}
			search := workspace_search(root, query) or {
				return encode_agent_tool_error('The workspace search query is invalid.')
			}
			json2.encode[WorkspaceSearchResult](search)
		}
		'workspace_propose_file_edit' {
			tool_arguments := json2.decode[map[string]json2.Any](call.function.arguments) or {
				return encode_agent_tool_error('Tool arguments must be a JSON object.')
			}
			path := string_tool_argument(tool_arguments, 'path') or {
				return encode_agent_tool_error('A relative file path is required.')
			}
			content := string_tool_argument(tool_arguments, 'content') or {
				return encode_agent_tool_error('Proposed UTF-8 file content is required.')
			}
			if tool_arguments.len != 2 {
				return encode_agent_tool_error('Unexpected tool argument.')
			}
			draft := prepare_workspace_edit(root, path, content) or {
				return encode_agent_tool_error('The workspace edit is invalid or unavailable: ${err.msg()}')
			}
			mut store := app.store
			proposal := store.create_workspace_edit(session_id, draft) or {
				return encode_agent_tool_error('The workspace edit could not be saved for review.')
			}
			json2.encode[AgentWorkspaceEditResult](AgentWorkspaceEditResult{
				id:   proposal.id
				path: proposal.path
				note: 'Stored for human review. The file has not been changed.'
			})
		}
		'workspace_propose_shell_command' {
			draft := parse_shell_tool_arguments(call.function.arguments, root) or {
				return encode_agent_tool_error('Shell command proposal is invalid: ${err.msg()}')
			}
			mut store := app.store
			proposal := store.create_shell_command(session_id, draft) or {
				return encode_agent_tool_error('Shell command proposal could not be saved for review.')
			}
			json2.encode[AgentShellCommandResult](AgentShellCommandResult{
				id:      proposal.id
				command: proposal.command
				cwd:     proposal.cwd
				note:    'Stored for human review. No command was executed.'
			})
		}
		else {
			return encode_agent_tool_error('This tool is not available.')
		}
	}
	return result
}

fn string_tool_argument(arguments map[string]json2.Any, key string) !string {
	value := arguments[key] or { return error('required string argument is missing') }
	if value !is string {
		return error('tool argument must be a string')
	}
	return value as string
}
