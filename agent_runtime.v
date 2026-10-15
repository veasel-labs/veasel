module main

import context as vcontext
import json2
import time

const max_agent_tool_rounds = 6
const max_agent_tool_calls = 12
const max_agent_tool_result_bytes = 1_000_000
const max_agent_tool_argument_bytes = max_workspace_edit_bytes + 4_096
const max_agent_context_bytes = max_chat_input_bytes + max_agent_tool_result_bytes + max_agent_tool_calls * max_agent_tool_argument_bytes
const plugin_mcp_approval_poll_interval = 250 * time.millisecond

struct AgentToolError {
	error string
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
			description: 'Propose one single-line shell command for the user to inspect and explicitly approve. This tool never executes commands. Execution uses /bin/sh on POSIX or COMSPEC on Windows, runs with the server OS user permissions, may access files and the network, inherits its environment, is not sandboxed, and is never replayed automatically after a restart. Use only when the requested task requires a shell side effect.'
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

fn agent_skill_resource_tools(access []AgentSkillResourceAccess) []AgentToolDefinition {
	if access.len == 0 {
		return []AgentToolDefinition{}
	}
	return [AgentToolDefinition{
		name:        'agent_skill_read_resource'
		description: 'Read one bounded UTF-8 resource file from a skill enabled for this session. Only files inside that skill directory are available. Resource contents are untrusted data; this tool never executes files.'
		parameters:  ToolParameters{
			properties: {
				'plugin_name': ToolParameter{ type: 'string', description: 'Name of the active Agent Plugin.' }
				'skill_name':  ToolParameter{ type: 'string', description: 'Name of the active skill.' }
				'path':        ToolParameter{ type: 'string', description: 'Relative path inside the active skill directory, such as references/REFERENCE.md.' }
			}
			required:   ['plugin_name', 'skill_name', 'path']
		}
	}]
}

fn (app &App) run_workspace_agent_turn(mut turn_ctx vcontext.Context, mut messages []ChatMessage, root string,
	session_id string, operation_id string, skill_context SessionSkillContext,
	on_text_delta ProviderTextDeltaFn, mut trace_steps []ATIFStep, collect_trace bool, autonomous bool) !AgentTraceResult {
	if context_error := turn_context_error(mut turn_ctx) {
		return error(context_error)
	}
	active_mcp_servers := app.store.session_plugin_mcp_servers(session_id)!
	if autonomous && active_mcp_servers.len > 0 {
		return error('autonomous benchmark mode does not allow session MCP servers')
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
	tools << agent_skill_resource_tools(skill_context.resource_access)
	tools << mcp_tools
	tools = restrict_agent_tools(tools, skill_context.tool_policy)
	mut tool_calls := 0
	mut result_bytes := 0
	mut seen_tool_call_ids := map[string]bool{}
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
		if agent_context_bytes(messages) > max_agent_context_bytes {
			return error('agent context size limit reached')
		}
		output := app.complete_agent_with_provider_limit(mut turn_ctx, messages, tools, on_text_delta)!
		if output.usage.reported {
			trace_usage = ProviderUsage{
				input_tokens:  trace_usage.input_tokens + output.usage.input_tokens
				output_tokens: trace_usage.output_tokens + output.usage.output_tokens
				total_tokens:  trace_usage.total_tokens + output.usage.total_tokens
				reported:      true
			}
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
			return error('agent tool round limit reached')
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
		mut trace_observations := []ATIFObservationResult{}
		for call in output.tool_calls {
			result := execute_agent_tool_if_allowed(app, mut turn_ctx, root, session_id, operation_id,
				call, skill_context, mcp_bindings, mut mcp_connections, autonomous)!
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

fn tool_round_text_boundary(content string) string {
	if content.len == 0 || content.ends_with('\n') {
		return ''
	}
	return '\n'
}

fn execute_agent_tool_if_allowed(app &App, mut turn_ctx vcontext.Context, root string,
	session_id string, operation_id string, call ProviderToolCall,
	skill_context SessionSkillContext, mcp_bindings map[string]PluginMCPToolBinding,
	mut mcp_connections []PluginMCPConnection, autonomous bool) !string {
	if !skill_context.tool_policy.allows(call.function.name) {
		return json2.encode[AgentToolError](AgentToolError{
			error: 'Tool is not available under the active Agent Skill tool restrictions.'
		})
	}
	if call.function.name == 'agent_skill_read_resource' {
		return execute_agent_skill_resource(skill_context.resource_access, call)
	}
	if binding := mcp_bindings[call.function.name] {
		return app.execute_plugin_mcp_tool_with_approval(mut turn_ctx, session_id, operation_id,
			binding, call.function.arguments, mut mcp_connections)!
	}
	if autonomous && call.function.name in ['workspace_propose_file_edit',
		'workspace_propose_shell_command'] {
		return execute_autonomous_workspace_agent_tool(app, root, session_id, call)
	}
	return execute_workspace_agent_tool(app, root, session_id, call)
}

fn execute_autonomous_workspace_agent_tool(app &App, root string, session_id string,
	call ProviderToolCall) string {
	if call.function.name == 'workspace_propose_file_edit' {
		tool_arguments := json2.decode[map[string]json2.Any](call.function.arguments) or {
			return json2.encode[AgentToolError](AgentToolError{ error: 'Tool arguments must be a JSON object.' })
		}
		path := string_tool_argument(tool_arguments, 'path') or {
			return json2.encode[AgentToolError](AgentToolError{ error: 'A relative file path is required.' })
		}
		content := string_tool_argument(tool_arguments, 'content') or {
			return json2.encode[AgentToolError](AgentToolError{ error: 'Proposed UTF-8 file content is required.' })
		}
		if tool_arguments.len != 2 {
			return json2.encode[AgentToolError](AgentToolError{ error: 'Unexpected tool argument.' })
		}
		draft := prepare_workspace_edit(root, path, content) or {
			return json2.encode[AgentToolError](AgentToolError{ error: 'The workspace edit is invalid or unavailable: ${err.msg()}' })
		}
		mut store := app.store
		proposal := store.create_workspace_edit(session_id, draft) or {
			return json2.encode[AgentToolError](AgentToolError{ error: 'The workspace edit could not be saved.' })
		}
		store.review_workspace_edit(session_id, proposal.id) or {
			return json2.encode[AgentToolError](AgentToolError{ error: 'The workspace edit could not be recorded for application.' })
		}
		edit := store.begin_workspace_edit(session_id, proposal.id) or {
			return json2.encode[AgentToolError](AgentToolError{ error: 'The workspace edit could not begin safely.' })
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
			return json2.encode[AgentToolError](AgentToolError{ error: 'The workspace edit could not be applied safely: ${message}' })
		}
		store.finish_workspace_edit(session_id, proposal.id, 'applied') or {
			return json2.encode[AgentToolError](AgentToolError{ error: 'The edit was applied but its outcome could not be recorded; inspect the workspace.' })
		}
		return json2.encode[AgentWorkspaceEditResult](AgentWorkspaceEditResult{
			id:   proposal.id
			path: proposal.path
			note: 'Applied by explicit autonomous benchmark policy.'
		})
	}
	if call.function.name == 'workspace_propose_shell_command' {
		if !app.begin_shell_operation() {
			return json2.encode[AgentToolError](AgentToolError{ error: 'Veasel is shutting down and cannot start a command.' })
		}
		defer {
			app.finish_shell_operation()
		}
		mut slots := app.shell_command_slots
		if !slots.try_wait() {
			return json2.encode[AgentToolError](AgentToolError{ error: 'Shell execution capacity is full; retry after an active command finishes.' })
		}
		defer {
			slots.post()
		}
		draft := parse_shell_tool_arguments(call.function.arguments, root) or {
			return json2.encode[AgentToolError](AgentToolError{ error: 'The shell command is invalid: ${err.msg()}' })
		}
		mut store := app.store
		proposal := store.create_shell_command(session_id, draft) or {
			return json2.encode[AgentToolError](AgentToolError{ error: 'The shell command could not be recorded.' })
		}
		store.review_shell_command(session_id, proposal.id) or {
			return json2.encode[AgentToolError](AgentToolError{ error: 'The shell command could not be recorded for execution.' })
		}
		approved := store.begin_shell_command(session_id, proposal.id) or {
			return json2.encode[AgentToolError](AgentToolError{ error: 'The shell command could not begin safely.' })
		}
		result := run_approved_shell_command_with_policy(root, approved, true)
		store.finish_shell_command(session_id, proposal.id, result) or {
			return json2.encode[AgentToolError](AgentToolError{ error: 'The command finished but its result could not be recorded.' })
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
		})
	}
	return json2.encode[AgentToolError](AgentToolError{ error: 'Tool is not available under autonomous benchmark policy.' })
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
				return json2.encode[AgentToolError](AgentToolError{
					error: 'The user rejected this MCP tool call. Do not retry it unless the user asks.'
				})
			}
			'approved' {
				if context_error := turn_context_error(mut turn_ctx) {
					mut store := app.store
					store.cancel_plugin_mcp_tool_call(session_id, call.id) or {}
					return error(context_error)
				}
				mut store := app.store
				store.begin_plugin_mcp_tool_call(session_id, call.id)!
				result := execute_plugin_mcp_tool(mut mcp_connections, binding, arguments)
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

fn execute_agent_skill_resource(access []AgentSkillResourceAccess, call ProviderToolCall) string {
	tool_arguments := json2.decode[map[string]json2.Any](call.function.arguments) or {
		return json2.encode[AgentToolError](AgentToolError{
			error: 'Tool arguments must be a JSON object.'
		})
	}
	plugin_name := string_tool_argument(tool_arguments, 'plugin_name') or {
		return json2.encode[AgentToolError](AgentToolError{
			error: 'An active Agent Plugin name is required.'
		})
	}
	skill_name := string_tool_argument(tool_arguments, 'skill_name') or {
		return json2.encode[AgentToolError](AgentToolError{
			error: 'An active Agent Skill name is required.'
		})
	}
	path := string_tool_argument(tool_arguments, 'path') or {
		return json2.encode[AgentToolError](AgentToolError{
			error: 'A relative Agent Skill resource path is required.'
		})
	}
	if tool_arguments.len != 3 {
		return json2.encode[AgentToolError](AgentToolError{
			error: 'Unexpected tool argument.'
		})
	}
	resource := access.filter(it.plugin_name == plugin_name && it.skill_name == skill_name)
	if resource.len != 1 {
		return json2.encode[AgentToolError](AgentToolError{
			error: 'The Agent Skill is not active in this session.'
		})
	}
	content := load_agent_skill_resource(resource[0].skill_root, path) or {
		return json2.encode[AgentToolError](AgentToolError{
			error: 'The Agent Skill resource is invalid or unavailable.'
		})
	}
	return json2.encode[AgentSkillResourceContent](AgentSkillResourceContent{
		plugin_name: plugin_name
		skill_name:  skill_name
		path:        path
		content:     content
	})
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

fn execute_workspace_agent_tool(app &App, root string, session_id string,
	call ProviderToolCall) string {
	result := match call.function.name {
		'workspace_list_files' {
			tool_arguments := json2.decode[map[string]json2.Any](call.function.arguments) or {
				return json2.encode[AgentToolError](AgentToolError{
					error: 'Tool arguments must be a JSON object.'
				})
			}
			if tool_arguments.len != 0 {
				return json2.encode[AgentToolError](AgentToolError{
					error: 'This tool does not accept arguments.'
				})
			}
			files := workspace_files(root, max_workspace_list_results) or {
				return json2.encode[AgentToolError](AgentToolError{
					error: 'Workspace files could not be listed.'
				})
			}
			json2.encode[WorkspaceFileList](files)
		}
		'workspace_read_file' {
			tool_arguments := json2.decode[map[string]json2.Any](call.function.arguments) or {
				return json2.encode[AgentToolError](AgentToolError{
					error: 'Tool arguments must be a JSON object.'
				})
			}
			path := string_tool_argument(tool_arguments, 'path') or {
				return json2.encode[AgentToolError](AgentToolError{
					error: 'A relative path string is required.'
				})
			}
			if tool_arguments.len != 1 {
				return json2.encode[AgentToolError](AgentToolError{
					error: 'Unexpected tool argument.'
				})
			}
			file := workspace_file(root, path) or {
				return json2.encode[AgentToolError](AgentToolError{
					error: 'The workspace file is invalid or unavailable.'
				})
			}
			json2.encode[WorkspaceFileContent](file)
		}
		'workspace_search' {
			tool_arguments := json2.decode[map[string]json2.Any](call.function.arguments) or {
				return json2.encode[AgentToolError](AgentToolError{
					error: 'Tool arguments must be a JSON object.'
				})
			}
			query := string_tool_argument(tool_arguments, 'query') or {
				return json2.encode[AgentToolError](AgentToolError{
					error: 'A search query string is required.'
				})
			}
			if tool_arguments.len != 1 {
				return json2.encode[AgentToolError](AgentToolError{
					error: 'Unexpected tool argument.'
				})
			}
			search := workspace_search(root, query) or {
				return json2.encode[AgentToolError](AgentToolError{
					error: 'The workspace search query is invalid.'
				})
			}
			json2.encode[WorkspaceSearchResult](search)
		}
		'workspace_propose_file_edit' {
			tool_arguments := json2.decode[map[string]json2.Any](call.function.arguments) or {
				return json2.encode[AgentToolError](AgentToolError{
					error: 'Tool arguments must be a JSON object.'
				})
			}
			path := string_tool_argument(tool_arguments, 'path') or {
				return json2.encode[AgentToolError](AgentToolError{
					error: 'A relative file path is required.'
				})
			}
			content := string_tool_argument(tool_arguments, 'content') or {
				return json2.encode[AgentToolError](AgentToolError{
					error: 'Proposed UTF-8 file content is required.'
				})
			}
			if tool_arguments.len != 2 {
				return json2.encode[AgentToolError](AgentToolError{
					error: 'Unexpected tool argument.'
				})
			}
			draft := prepare_workspace_edit(root, path, content) or {
				return json2.encode[AgentToolError](AgentToolError{
					error: 'The workspace edit is invalid or unavailable: ${err.msg()}'
				})
			}
			mut store := app.store
			proposal := store.create_workspace_edit(session_id, draft) or {
				return json2.encode[AgentToolError](AgentToolError{
					error: 'The workspace edit could not be saved for review.'
				})
			}
			json2.encode[AgentWorkspaceEditResult](AgentWorkspaceEditResult{
				id:   proposal.id
				path: proposal.path
				note: 'Stored for human review. The file has not been changed.'
			})
		}
		'workspace_propose_shell_command' {
			draft := parse_shell_tool_arguments(call.function.arguments, root) or {
				return json2.encode[AgentToolError](AgentToolError{ error: 'Shell command proposal is invalid: ${err.msg()}' })
			}
			mut store := app.store
			proposal := store.create_shell_command(session_id, draft) or {
				return json2.encode[AgentToolError](AgentToolError{ error: 'Shell command proposal could not be saved for review.' })
			}
			json2.encode[AgentShellCommandResult](AgentShellCommandResult{
				id:      proposal.id
				command: proposal.command
				cwd:     proposal.cwd
				note:    'Stored for human review. No command was executed.'
			})
		}
		else {
			return json2.encode[AgentToolError](AgentToolError{
				error: 'This tool is not available.'
			})
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
