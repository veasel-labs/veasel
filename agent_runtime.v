module main

import json2

const max_agent_tool_rounds = 6
const max_agent_tool_calls = 12
const max_agent_tool_result_bytes = 1_000_000
const max_agent_tool_argument_bytes = max_workspace_edit_bytes + 4_096
const max_agent_context_bytes = max_chat_input_bytes + max_agent_tool_result_bytes + max_agent_tool_calls * max_agent_tool_argument_bytes

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
	]
}

fn (app &App) run_workspace_agent_turn(mut messages []ChatMessage, root string,
	session_id string) !CompletionOutput {
	tools := workspace_agent_tools()
	mut tool_calls := 0
	mut result_bytes := 0
	mut seen_tool_call_ids := map[string]bool{}
	for round in 0 .. max_agent_tool_rounds {
		if agent_context_bytes(messages) > max_agent_context_bytes {
			return error('agent context size limit reached')
		}
		output := app.complete_agent_with_provider_limit(messages, tools)!
		if output.tool_calls.len == 0 {
			if output.content.trim_space().len == 0 {
				return error('model returned no final response')
			}
			return output
		}
		if tool_calls + output.tool_calls.len > max_agent_tool_calls {
			return error('agent tool call limit reached')
		}
		if round == max_agent_tool_rounds - 1 {
			return error('agent tool round limit reached')
		}
		for call in output.tool_calls {
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
		messages << ChatMessage{
			role:       'assistant'
			content:    output.content
			tool_calls: output.tool_calls
		}
		tool_calls += output.tool_calls.len
		for call in output.tool_calls {
			result := execute_workspace_agent_tool(app, root, session_id, call)
			result_bytes += result.len
			if result_bytes > max_agent_tool_result_bytes {
				return error('agent tool result limit reached')
			}
			messages << ChatMessage{
				role:                  'tool'
				name:                  call.function.name
				tool_call_id:          call.id
				provider_tool_call_id: call.provider_call_id
				content:               result
			}
		}
	}
	return error('agent tool round limit reached')
}

fn agent_context_bytes(messages []ChatMessage) int {
	mut total := 0
	for message in messages {
		total += message.content.len
		total += message.name.len + message.tool_call_id.len + message.provider_tool_call_id.len
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
