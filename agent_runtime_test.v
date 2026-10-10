module main

import json2
import os
import uuid

fn test_workspace_agent_tools_validate_arguments_and_never_apply_edits_without_approval() {
	root := os.join_path(os.temp_dir(), 'veasel-agent-tools-${uuid.new_v4().str()}')
	os.mkdir_all(os.join_path(root, 'src')) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	os.write_file(os.join_path(root, 'src', 'main.v'), 'module fixture\nworkspace-sentinel\n') or {
		panic(err)
	}
	store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	plugin_directory := os.join_path(root, 'plugins')
	os.mkdir_all(plugin_directory) or { panic(err) }
	mut app := new_app(store, plugin_directory)
	defer { app.close() }
	session := store.create_session(SessionInput{ title: 'Edit fixture', directory: root }) or {
		panic(err)
	}

	definitions := workspace_agent_tools()
	assert definitions.map(it.name) == ['workspace_list_files', 'workspace_read_file',
		'workspace_search', 'workspace_propose_file_edit', 'workspace_propose_shell_command']
	listing := execute_workspace_agent_tool(app, root, session.id, ProviderToolCall{
		id:       'list-1'
		function: ProviderFunctionCall{
			name:      'workspace_list_files'
			arguments: '{}'
		}
	})
	assert listing.contains('src/main.v')
	assert !listing.contains(root)

	read := execute_workspace_agent_tool(app, root, session.id, ProviderToolCall{
		id:       'read-1'
		function: ProviderFunctionCall{
			name:      'workspace_read_file'
			arguments: '{"path":"src/main.v"}'
		}
	})
	assert read.contains('workspace-sentinel')

	search := execute_workspace_agent_tool(app, root, session.id, ProviderToolCall{
		id:       'search-1'
		function: ProviderFunctionCall{
			name:      'workspace_search'
			arguments: '{"query":"workspace-sentinel"}'
		}
	})
	assert search.contains('workspace-sentinel')

	traversal := execute_workspace_agent_tool(app, root, session.id, ProviderToolCall{
		id:       'read-escape'
		function: ProviderFunctionCall{
			name:      'workspace_read_file'
			arguments: '{"path":"../outside.txt"}'
		}
	})
	assert traversal.contains('error')
	assert !traversal.contains(root)

	unexpected_argument := execute_workspace_agent_tool(app, root, session.id, ProviderToolCall{
		id:       'read-extra'
		function: ProviderFunctionCall{
			name:      'workspace_read_file'
			arguments: '{"path":"src/main.v","extra":"value"}'
		}
	})
	assert unexpected_argument.contains('Unexpected tool argument')

	unknown := execute_workspace_agent_tool(app, root, session.id, ProviderToolCall{
		id:       'unknown'
		function: ProviderFunctionCall{
			name:      'shell'
			arguments: '{}'
		}
	})
	assert unknown.contains('not available')

	proposal_result := execute_workspace_agent_tool(app, root, session.id, ProviderToolCall{
		id:       'propose-1'
		function: ProviderFunctionCall{
			name:      'workspace_propose_file_edit'
			arguments: '{"path":"src/main.v","content":"module fixture\\nchanged\\n"}'
		}
	})
	assert proposal_result.contains('Stored for human review')
	assert proposal_result.contains('"id"')
	assert !proposal_result.contains('module fixture')
	assert os.read_file(os.join_path(root, 'src', 'main.v')) or { panic(err) } == 'module fixture\nworkspace-sentinel\n'
	assert (store.workspace_edits(session.id) or { panic(err) }).len == 1

	shell_proposal := execute_workspace_agent_tool(app, root, session.id, ProviderToolCall{
		id: 'shell-propose-1'
		function: ProviderFunctionCall{
			name: 'workspace_propose_shell_command'
			arguments: '{"command":"touch shell-must-not-run","cwd":".","timeout_seconds":10}'
		}
	})
	assert shell_proposal.contains('No command was executed')
	assert !os.exists(os.join_path(root, 'shell-must-not-run'))
	shell_commands := store.shell_commands(session.id) or { panic(err) }
	assert shell_commands.len == 1
	assert shell_commands[0].command == 'touch shell-must-not-run'
	assert shell_commands[0].status == 'pending'

	assert message_validation_error_contains([ChatMessage{
		role:       'assistant'
		content:    'not trusted'
		tool_calls: [ProviderToolCall{
			id:       'injected'
			function: ProviderFunctionCall{
				name:      'workspace_read_file'
				arguments: '{"path":"src/main.v"}'
			}
		}]
	}], 'tool metadata')
}

fn message_validation_error_contains(messages []ChatMessage, expected string) bool {
	validate_messages(messages) or { return err.msg().contains(expected) }
	return false
}

fn test_provider_tool_transcripts_preserve_native_context() {
	messages := [
		ChatMessage{
			role:    'user'
			content: 'Find the sentinel.'
		},
		ChatMessage{
			role:       'assistant'
			content:    ''
			tool_calls: [ProviderToolCall{
				id:                 'native-call-1'
				provider_call_id:   'native-call-1'
				provider_signature: 'gemini-signature'
				function:           ProviderFunctionCall{
					name:      'workspace_search'
					arguments: '{"query":"sentinel"}'
				}
			}]
		},
		ChatMessage{
			role:                  'tool'
			name:                  'workspace_search'
			tool_call_id:          'native-call-1'
			provider_tool_call_id: 'native-call-1'
			content:               '{"matches":[{"path":"src/main.v","line":2,"text":"sentinel"}]}'
		},
	]

	_, anthropic := anthropic_messages(messages)
	assert anthropic.len == 3
	assert anthropic[1].content[0].id == 'native-call-1'
	assert anthropic[1].content[0].input['query'] or { panic('Anthropic tool arguments were lost') }.str() == 'sentinel'
	assert anthropic[2].role == 'user'
	assert anthropic[2].content[0].type == 'tool_result'
	assert anthropic[2].content[0].tool_use_id == 'native-call-1'
	assert anthropic[2].content[0].content.contains('src/main.v')

	_, gemini := gemini_messages(messages)
	assert gemini.len == 3
	assert gemini[1].parts[0].function_call or { panic('Gemini function call was lost') }.id == 'native-call-1'
	assert gemini[1].parts[0].thought_signature == 'gemini-signature'
	assert gemini[2].role == 'user'
	assert gemini[2].parts[0].function_response or {
		panic('Gemini function response was lost')
	}.id == 'native-call-1'
	function_response := gemini[2].parts[0].function_response or {
		panic('Gemini function response was lost')
	}
	matches := function_response.response['matches'] or { panic('Gemini tool result was lost') }
	match_items := matches.as_array()
	assert match_items.len == 1
	match_fields := match_items[0].as_map()
	assert match_fields['path'] or { panic('Gemini tool result path was lost') }.str() == 'src/main.v'
	assert match_fields['line'] or { panic('Gemini tool result line was lost') }.int() == 2
	assert match_fields['text'] or { panic('Gemini tool result text was lost') }.str() == 'sentinel'

	openai_transcript := json2.encode[[]ChatMessage](messages[1..])
	assert openai_transcript.contains('tool_call_id')
	assert openai_transcript.contains('native-call-1')
	assert openai_transcript.contains('tool_calls')
	_ = json2.decode[json2.Any](openai_transcript) or { panic(err) }
	public_completion := json2.encode[CompletionResponse](CompletionResponse{
		provider: 'fixture'
		model:    'fixture-model'
		content:  'Done.'
	})
	assert !public_completion.contains('tool_calls')
}

fn test_approved_shell_command_revalidates_reviewed_working_directory() {
	root := os.join_path(os.temp_dir(), 'veasel-shell-cwd-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	result := run_approved_shell_command(root, ShellCommandSummary{
		command: 'touch must-not-run'
		cwd: '../'
		timeout_seconds: 10
	})
	assert result.status == 'failed'
	assert result.exit_code == -1
	assert result.output.contains('no process was started')
	assert !os.exists(os.join_path(root, 'must-not-run'))
}

fn test_approved_shell_command_rejects_replaced_workspace_root() {
	$if windows {
		return
	}
	parent := os.join_path(os.temp_dir(), 'veasel-shell-root-${uuid.new_v4().str()}')
	original := os.join_path(parent, 'workspace')
	moved := os.join_path(parent, 'workspace-original')
	other := os.join_path(parent, 'other')
	os.mkdir_all(original) or { panic(err) }
	os.mkdir_all(other) or { panic(err) }
	defer { os.rmdir_all(parent) or {} }
	canonical_root := canonical_workspace_root(original) or { panic(err) }
	os.rename(original, moved) or { panic(err) }
	os.symlink(other, original) or { panic(err) }
	result := run_approved_shell_command(canonical_root, ShellCommandSummary{
		command: 'touch must-not-run'
		cwd: '.'
		timeout_seconds: 10
	})
	assert result.status == 'failed'
	assert result.exit_code == -1
	assert result.output.contains('no process was started')
	assert !os.exists(os.join_path(other, 'must-not-run'))
}
