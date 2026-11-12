module main

import context as vcontext
import json2
import os
import time

const max_agent_tool_rounds = 24
const max_agent_tool_calls = 48
const agent_tool_loop_warning_threshold = 3
const agent_tool_loop_stop_threshold = 5
const agent_search_term_separators = ' \t\r\n,;:()[]{}"\'`./\\_-'
const tool_budget_summary_note = 'The tool budget for this turn is spent. Pending tool calls were not run. Reply in text only: what is already done, what is unfinished, and the single next step.'
const agent_code_change_retry_prompt = 'You have not proposed any workspace edits yet. The user explicitly asked for a code change. Inspect the relevant files and tests, then use workspace_propose_file_edit for the requested change. For a focused replacement, pass the exact existing text as old_text and the replacement as new_text; this preserves all other file content. Do not claim the work is complete without proposing the edits.'
const agent_code_change_retry_after_no_read_prompt = 'You still have not read any source file. Do not list the directory again or summarize it. Use workspace_search with a distinctive term from the requested behavior to locate the implementation, then workspace_read_file on the relevant source and test. After reading them, propose the requested focused change with workspace_propose_file_edit. Do not claim completion without an edit proposal.'
const agent_code_change_retry_after_read_prompt = 'You have inspected source, but no edit proposal was made. Re-check the original request and the files already read; the request still applies, so do not ask the user to repeat details. Search using one or more distinctive terms from the original request to locate the implementation or test that directly matches the requested behavior. Do not make cosmetic or unrelated edits. After confirming the relevant code, propose a focused change that satisfies the request. Never claim completion without an edit proposal.'
const agent_code_change_edit_recovery_prompt = 'The edit proposal failed validation and no file was changed. Re-read the current matched file, then create a fresh focused proposal using exact text from that current file. Do not reuse the failed old_text or claim the change succeeded. The original request still applies.'
const agent_code_change_verification_prompt = 'The requested code edit was applied. Before reporting completion, use workspace_propose_shell_command to run a relevant test, typecheck, or build requested by the user. Inspect the command result and fix any failure before finishing. Report only checks that actually ran.'
const agent_code_change_verification_failure_prompt = 'The requested verification command did not succeed. Inspect its output, fix the code or test issue with workspace tools, then rerun the relevant verification command. Do not report this task as complete until a requested check succeeds.'
const agent_code_change_exploration_nudge = 'You have spent several tool calls exploring without changing files. Stop broad discovery now: inspect only the files directly related to the requested change and the most relevant tests, then use workspace_propose_file_edit to implement it. For a focused replacement, pass the exact existing text as old_text and the replacement as new_text. Keep the change scoped to the user request.'
const agent_code_change_system_instruction = 'For an explicit code-change request, start with a workspace tool call immediately. Do not send an acknowledgement, plan, or promise before your first workspace tool call. If the request names a file, read it; otherwise search for a distinctive term from the requested behavior. Then read the complete target file and relevant tests, and propose a focused edit with workspace_propose_file_edit before answering. For a localized replacement, pass the exact current text as old_text and the requested text as new_text; the tool preserves all other bytes and requires a unique match. Use complete file content only for broader edits. Never replace a file with a fragment or a description of the edit. A file listing or summary is not a completed change. If the request asks for tests, checks, or a build, run a relevant verification command after the edit and fix failures before reporting completion. Report only checks that actually succeeded. Do not ask for details already present in the request. If a necessary detail or permission is missing, identify the concrete blocker.'
const agent_code_change_exploration_nudge_after = 4
const max_agent_code_change_followthrough_retries = 2
const max_agent_code_change_edit_recovery_attempts = 1
const max_agent_tool_result_bytes = 1_000_000
const max_agent_tool_argument_bytes = max_workspace_edit_bytes + 4_096

fn agent_tool_available_in_turn(name string, tools []AgentToolDefinition) bool {
	return tools.any(it.name == name)
}

fn agent_context_byte_limit() int {
	return chat_input_byte_limit() + max_agent_tool_result_bytes + max_agent_tool_calls * max_agent_tool_argument_bytes
}

fn agent_original_user_request_text(content string) string {
	focus_start := content.index(repository_map_focus_open) or { return content.trim_space() }
	return content[..focus_start].trim_space()
}

fn agent_latest_user_request_text(messages []ChatMessage) string {
	for message in messages.reverse() {
		if message.role == 'user' {
			return agent_original_user_request_text(message.content)
		}
	}
	return ''
}

fn explicit_agent_code_change_request(messages []ChatMessage) bool {
	latest_user_message := agent_latest_user_request_text(messages).to_lower()
	if latest_user_message.len == 0 || latest_user_message.starts_with('do not ')
		|| latest_user_message.starts_with("don't ") || latest_user_message.starts_with('explain ')
		|| latest_user_message.starts_with('review ') || latest_user_message.starts_with('summarize ')
		|| latest_user_message.starts_with('what ') || latest_user_message.starts_with('how ') {
		return false
	}
	for no_edit_instruction in ['do not edit any files', 'do not edit files', "don't edit any files",
		"don't edit files", 'do not change any files', 'do not change files', "don't change any files",
		"don't change files", 'do not edit the source file', 'do not change the source file',
		"don't edit the source file", "don't change the source file", 'ask me before editing',
		'ask before editing', 'ask me before making changes', 'ask before making changes',
		'before you edit files', 'before editing files', 'before changing files'] {
		if latest_user_message.contains(no_edit_instruction) {
			return false
		}
	}
	mut request := latest_user_message
	for prefix in ['please ', 'could you ', 'can you ', 'would you ', 'i want you to ', 'help me '] {
		if request.starts_with(prefix) {
			request = request[prefix.len..]
			break
		}
	}
	for verb in ['edit ', 'change ', 'update ', 'fix ', 'implement ', 'add ', 'create ', 'remove ',
		'delete ', 'rename ', 'refactor ', 'modify ', 'write ', 'replace '] {
		if request.starts_with(verb) {
			return true
		}
		// Common coding requests lead with a file or location: "In X, change Y".
		// Explanatory questions starting with "how" were excluded above.
		for separator in [', ', ': ', '\n'] {
			if request.contains('${separator}${verb}') {
				return true
			}
		}
	}
	return false
}

fn agent_search_query_matches_request(query string, request string) bool {
	stop_words := ['about', 'add', 'after', 'also', 'before', 'build', 'change', 'check', 'code',
		'complete', 'create', 'current', 'delete', 'directly', 'edit', 'file', 'fix', 'focused',
		'from', 'have', 'implement', 'implementation', 'into', 'please', 'remove', 'request',
		'requested', 'run', 'search', 'task', 'that', 'the', 'their', 'then', 'test', 'this', 'through',
		'update', 'verify', 'with', 'work', 'would']
	single_term_task_concepts := ['mobile', 'sidebar', 'responsive', 'viewport', 'keyboard']
	query_terms := query.to_lower().split_any(agent_search_term_separators)
	request_terms := request.to_lower().split_any(agent_search_term_separators)
	mut matched_terms := map[string]bool{}
	for query_term in query_terms {
		if query_term.len < 4 || query_term in stop_words {
			continue
		}
		for request_term in request_terms {
			if request_term.len < 4 || request_term in stop_words {
				continue
			}
			if query_term == request_term || (query_term.len >= 4 && request_term.starts_with(query_term))
				|| (request_term.len >= 4 && query_term.starts_with(request_term)) {
				matched_terms[request_term] = true
			}
		}
	}
	// Two distinct task terms resist generic overlap. A single long term remains
	// useful for searches built around a distinctive name or concept from the request.
	return matched_terms.len >= 2 || query_terms.any(it in single_term_task_concepts
		&& it in request_terms) || matched_terms.keys().any(it.len >= 9)
}

fn agent_system_code_change_instruction(explicit_request bool) string {
	return if explicit_request { agent_code_change_system_instruction } else { '' }
}

fn explicit_agent_verification_request(messages []ChatMessage) bool {
	mut request := ''
	for message in messages {
		if message.role == 'user' {
			request = agent_original_user_request_text(message.content)
		}
	}
	text := request.to_lower()
	return text.contains('test') || text.contains('typecheck') || text.contains('type check')
		|| text.contains('build') || text.contains('verify') || text.contains('run checks')
}

fn agent_code_change_verification_tools(tools []AgentToolDefinition, required bool,
	workspace_effect_applied bool, verification_succeeded bool, verification_failed bool) []AgentToolDefinition {
	if !required || !workspace_effect_applied || verification_succeeded || verification_failed {
		return tools
	}
	return tools.filter(it.name == 'workspace_propose_shell_command')
}

fn agent_final_response_for_verification(content string, required bool,
	workspace_effect_applied bool, verification_succeeded bool) string {
	if required && workspace_effect_applied && !verification_succeeded {
		return 'The requested code change was applied, but its requested verification did not succeed. This task is not complete. ${content}'
	}
	return content
}

fn agent_code_change_tools_for_progress(tools []AgentToolDefinition, explicit_request bool,
	edit_attempted bool, workspace_read_count int, workspace_search_performed bool,
	workspace_read_after_search bool, followthrough_retried bool) []AgentToolDefinition {
	if !explicit_request || edit_attempted {
		return tools
	}
	if workspace_read_count == 0 && !workspace_search_performed {
		// Start explicit code changes with a request-directed search. A directory
		// listing or an arbitrary first file is not evidence that the target was
		// located, and small local models have repeatedly mistaken those for task
		// progress.
		return tools.filter(it.name == 'workspace_search')
	}
	if followthrough_retried && workspace_read_count == 0 {
		return tools.filter(it.name in ['workspace_read_file', 'workspace_search'])
	}
	if workspace_read_count > 0 && workspace_search_performed && workspace_read_after_search {
		// A first successful read may be an unrelated file or a bounded excerpt.
		// Keep focused search and read available so the model can locate the target
		// without reopening broad directory enumeration or gaining shell access.
		return tools.filter(it.name in ['workspace_read_file', 'workspace_search',
			'workspace_propose_file_edit'])
	}
	if workspace_read_count > 0 {
		// Require a matching focused search and a subsequent read before edits are
		// available; a one-file opportunistic edit is not enough context.
		return tools.filter(it.name in ['workspace_read_file', 'workspace_search'])
	}
	if followthrough_retried {
		return tools.filter(it.name in ['workspace_read_file', 'workspace_search',
			'workspace_propose_file_edit'])
	}
	return tools.filter(it.name in ['workspace_read_file', 'workspace_search'])
}

fn agent_code_change_tools_after_edit_failures(tools []AgentToolDefinition, explicit_request bool,
	failed_edit_proposals int) []AgentToolDefinition {
	if explicit_request && failed_edit_proposals > max_agent_code_change_edit_recovery_attempts {
		return tools.filter(it.name in ['workspace_read_file', 'workspace_search'])
	}
	return tools
}

fn agent_code_change_followthrough_retry_available(explicit_request bool, tools []AgentToolDefinition,
	retries int, proposal_attempted bool, request_deadline time.Time) bool {
	if retries >= max_agent_code_change_followthrough_retries || proposal_attempted || !explicit_request
		|| request_deadline - time.now() < 20 * time.second {
		return false
	}
	return tools.any(it.name == 'workspace_propose_file_edit')
}

fn agent_discard_buffered_text_on_provider_error(explicit_request bool) bool {
	return explicit_request
}

fn agent_code_change_exploration_nudge_available(explicit_request bool, tools []AgentToolDefinition,
	read_only_calls int, nudged bool, proposal_attempted bool, request_deadline time.Time) bool {
	if !explicit_request || nudged || proposal_attempted || read_only_calls < agent_code_change_exploration_nudge_after
		|| request_deadline - time.now() < 20 * time.second {
		return false
	}
	return tools.any(it.name == 'workspace_propose_file_edit')
}

const plugin_mcp_approval_poll_interval = 250 * time.millisecond

// Workspace list/read/search have no durable side effects and may run concurrently
// when a provider returns multiple tools in one round. Skill load/read stay
// sequential so turn-scoped resource grants stay ordered; edits/shell/MCP never
// parallelize.
fn agent_tool_allows_parallel_readonly(name string) bool {
	return name in ['workspace_list_files', 'workspace_read_file', 'workspace_search']
}

// Count all built-in read-only exploration toward the code-change nudge. This
// is broader than parallel safety: skill reads and subagent runs stay serial.
fn agent_tool_is_readonly_exploration(name string) bool {
	return agent_tool_allows_parallel_readonly(name)
		|| name in ['subagent_run', 'agent_skill_load', 'agent_skill_read_resource']
}

fn agent_tool_readonly_run_end(calls []ProviderToolCall, start int) int {
	mut end := start
	for end < calls.len && agent_tool_allows_parallel_readonly(calls[end].function.name) {
		end++
	}
	return end
}

struct ParallelReadonlyToolResult {
	index                    int
	result                   string
	workspace_read_attempted bool
	workspace_read_succeeded bool
}

struct AgentToolExecutionResult {
	result                   string
	workspace_read_succeeded bool
}

struct AgentToolNote {
	note string
}

enum AgentToolLoopVerdict {
	ok
	warning
	stop
}

struct AgentToolLoopTracker {
mut:
	last_signature string
	consecutive    int
}

fn append_canonical_agent_tool_json(value json2.Any, mut output []u8) {
	match value {
		map[string]json2.Any {
			output << `{`
			mut keys := value.keys()
			keys.sort()
			for index, key in keys {
				if index > 0 {
					output << `,`
				}
				json2.encode_append(key, mut output)
				output << `:`
				append_canonical_agent_tool_json(value[key] or { json2.null }, mut output)
			}
			output << `}`
		}
		[]json2.Any {
			output << `[`
			for index, item in value {
				if index > 0 {
					output << `,`
				}
				append_canonical_agent_tool_json(item, mut output)
			}
			output << `]`
		}
		else {
			json2.encode_append(value, mut output)
		}
	}
}

fn agent_tool_call_signature(call ProviderToolCall) string {
	mut encoded := []u8{cap: call.function.name.len + call.function.arguments.len + 16}
	json2.encode_append(call.function.name, mut encoded)
	encoded << `:`
	decoded_arguments := json2.decode[json2.Any](call.function.arguments) or {
		encoded << call.function.arguments.bytes()
		return workspace_content_hash(encoded.bytestr())
	}
	append_canonical_agent_tool_json(decoded_arguments, mut encoded)
	return workspace_content_hash(encoded.bytestr())
}

fn (mut tracker AgentToolLoopTracker) inspect(call ProviderToolCall) AgentToolLoopVerdict {
	signature := agent_tool_call_signature(call)
	if signature == tracker.last_signature {
		tracker.consecutive++
	} else {
		tracker.last_signature = signature
		tracker.consecutive = 1
	}
	if tracker.consecutive >= agent_tool_loop_stop_threshold {
		return .stop
	}
	if tracker.consecutive == agent_tool_loop_warning_threshold {
		return .warning
	}
	return .ok
}

fn agent_tool_loop_warning(call ProviderToolCall) string {
	return 'The last ${agent_tool_loop_warning_threshold} tool calls were identical (${call.function.name}). Change the tool or its arguments to make progress.'
}

fn agent_tool_loop_stop_note(call ProviderToolCall) string {
	return encode_agent_tool_note('Repeated identical ${call.function.name} call was not run to prevent an execution loop. Change the tool or its arguments to continue.')
}

fn append_agent_tool_loop_warnings(mut messages []ChatMessage, mut trace_steps []ATIFStep,
	warnings []string, collect_trace bool) {
	for warning in warnings {
		messages << ChatMessage{
			role:    'user'
			content: warning
		}
		if collect_trace {
			trace_steps << ATIFStep{
				step_id: trace_steps.len + 1
				source:  'system'
				message: warning
			}
		}
	}
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
	if tool_arguments.len != 1 && tool_arguments.len != 3 {
		return none
	}
	path := string_tool_argument(tool_arguments, 'path') or { return none }
	if path.len == 0 {
		return none
	}
	// Preserve the path spelling: whitespace and backslashes can be literal
	// filename characters on supported platforms, so normalizing them could
	// suppress a distinct read.
	return path
}

fn workspace_read_identity_from_call(call ProviderToolCall) ?string {
	path := workspace_read_path_from_call(call) or { return none }
	fields := json2.decode[map[string]json2.Any](call.function.arguments) or { return none }
	start, count := workspace_read_range_arguments(fields) or { return none }
	return if start == 0 {
		json2.encode[[]string]([path])
	} else {
		json2.encode[[]string]([path, start.str(), count.str()])
	}
}

fn agent_workspace_read_succeeded_since(call ProviderToolCall, previous_reads map[string]bool,
	current_reads map[string]bool) bool {
	identity := workspace_read_identity_from_call(call) or { return false }
	return identity !in previous_reads && identity in current_reads
}

fn agent_workspace_file_was_read(path string, reads map[string]bool) bool {
	return reads[json2.encode[[]string]([path])]
}

fn agent_workspace_read_call_allowed(call ProviderToolCall, explicit_request bool,
	search_performed bool, search_match_paths map[string]bool) bool {
	if !explicit_request {
		return true
	}
	path := workspace_read_path_from_call(call) or { return false }
	return search_performed && path in search_match_paths
}

fn agent_workspace_search_call_relevant(call ProviderToolCall, explicit_request bool,
	request string) bool {
	if !explicit_request {
		return true
	}
	search_arguments := json2.decode[map[string]json2.Any](call.function.arguments) or {
		return false
	}
	query := string_tool_argument(search_arguments, 'query') or { return false }
	return agent_search_query_matches_request(query, request)
}

fn workspace_read_range_arguments(arguments map[string]json2.Any) !(int, int) {
	has_start := 'start_line' in arguments
	has_count := 'line_count' in arguments
	has_end := 'end_line' in arguments
	if (has_count && has_end) || (has_start != (has_count || has_end)) {
		return error('start_line must be paired with either line_count or end_line.')
	}
	if arguments.len != if has_start { 3 } else { 1 } {
		return error('Unexpected tool argument.')
	}
	if !has_start {
		return 0, 0
	}
	start := arguments['start_line'] or { return error('start_line is required.') }
	end_or_count := arguments[if has_end { 'end_line' } else { 'line_count' }] or {
		return error('line_count or end_line is required.')
	}
	if start !is f64 || end_or_count !is f64 {
		return error('start_line and range bound must be integers.')
	}
	start_value := start.f64()
	bound_value := end_or_count.f64()
	if start_value < 1 || start_value > f64(max_workspace_file_bytes)
		|| bound_value < 1 || bound_value > f64(max_workspace_file_bytes)
		|| start_value != f64(int(start_value)) || bound_value != f64(int(bound_value)) {
		return error('start_line and range bound must be positive whole numbers within the documented limits.')
	}
	start_line := int(start_value)
	range_count := if has_end { int(bound_value) - start_line + 1 } else { int(bound_value) }
	if range_count < 1 || range_count > max_workspace_read_range_lines {
		return error('line range must contain 1 to ${max_workspace_read_range_lines} lines.')
	}
	return start_line, range_count
}

fn duplicate_workspace_read_note(path string) string {
	return encode_agent_tool_note('Already provided this turn for path "${path}". Reuse the earlier workspace_read_file result; do not request it again.')
}

fn agent_tool_may_mutate_workspace(name string, mcp_bindings map[string]PluginMCPToolBinding) bool {
	return name in ['workspace_propose_file_edit', 'workspace_propose_shell_command']
		|| name in mcp_bindings
}

// execute_parallel_readonly_workspace_tools runs a read-only batch concurrently.
// Duplicate workspace_read_file paths in the same batch or already seen this turn
// receive a short note instead of re-injecting file bytes.
fn execute_parallel_readonly_workspace_tools(app &App, root string, session_id string,
	calls []ProviderToolCall, tool_policy AgentToolPolicy, mut read_paths map[string]bool,
	loop_skip_notes map[string]string) []string {
	mut ordered := []string{len: calls.len}
	mut run_indexes := []int{cap: calls.len}
	mut run_calls := []ProviderToolCall{cap: calls.len}
	mut pending_read_indexes := map[string]int{}
	mut duplicate_read_indexes := map[int]int{}
	for i, call in calls {
		if note := loop_skip_notes[call.id] {
			ordered[i] = note
			continue
		}
		// A denied read did not provide any workspace content, so it must not
		// poison the turn-scoped duplicate-read cache.
		if tool_policy.allows(call.function.name) {
			if identity := workspace_read_identity_from_call(call) {
				path := workspace_read_path_from_call(call) or { '' }
				if read_paths[identity] || read_paths[json2.encode[[]string]([path])] {
					ordered[i] = duplicate_workspace_read_note(path)
					continue
				}
				if primary_index := pending_read_indexes[identity] {
					duplicate_read_indexes[i] = primary_index
					continue
				}
				pending_read_indexes[identity] = i
			}
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
	mut run_results := []ParallelReadonlyToolResult{len: run_calls.len}
	for _ in 0 .. run_calls.len {
		item := <-results_ch
		run_results[item.index] = item
	}
	mut successful_reads := map[int]bool{}
	for i, call_index in run_indexes {
		read_result := run_results[i]
		ordered[call_index] = read_result.result
		if read_result.workspace_read_attempted {
			if identity := workspace_read_identity_from_call(run_calls[i]) {
				if read_result.workspace_read_succeeded {
					read_paths[identity] = true
					successful_reads[call_index] = true
				} else {
					read_paths.delete(identity)
				}
			}
		}
	}
	for duplicate_index, primary_index in duplicate_read_indexes {
		if path := workspace_read_path_from_call(calls[duplicate_index]) {
			ordered[duplicate_index] = if successful_reads[primary_index] {
				duplicate_workspace_read_note(path)
			} else {
				ordered[primary_index]
			}
		}
	}
	return ordered
}

fn execute_parallel_readonly_workspace_tool_worker(app &App, root string, session_id string,
	tool_policy AgentToolPolicy, index int, call ProviderToolCall, results_ch chan ParallelReadonlyToolResult) {
	mut result := ''
	mut workspace_read_attempted := false
	mut workspace_read_succeeded := false
	if !tool_policy.allows(call.function.name) {
		result = encode_agent_tool_error('Tool is not available under the active Agent Skill tool restrictions.')
	} else if call.function.name == 'workspace_read_file' {
		workspace_read_attempted = true
		read_result := execute_workspace_read_file_tool(root, call)
		result = sanitize_agent_tool_result(read_result.result)
		workspace_read_succeeded = read_result.workspace_read_succeeded
	} else {
		result = sanitize_agent_tool_result(execute_workspace_agent_tool(app, root, session_id,
			call))
	}
	results_ch <- ParallelReadonlyToolResult{
		index:                    index
		result:                   result
		workspace_read_attempted: workspace_read_attempted
		workspace_read_succeeded: workspace_read_succeeded
	}
}

// execute_agent_tool_batch runs adjacent read-only workspace calls concurrently,
// with every other tool acting as a sequential barrier. Results always remain in
// provider call order, and repeated file reads stay deduplicated across waves.
fn execute_agent_tool_batch(app &App, mut turn_ctx vcontext.Context, root string,
	session_id string, operation_id string, calls []ProviderToolCall,
	mut skill_context SessionSkillContext, mcp_bindings map[string]PluginMCPToolBinding,
	mut mcp_connections []PluginMCPConnection, policy ExecutionPolicyTurn,
	mut read_paths map[string]bool, loop_skip_notes map[string]string) ![]string {
	if calls.len > 1 && agent_tool_readonly_run_end(calls, 0) == calls.len {
		if context_error := turn_context_error(mut turn_ctx) {
			return error(context_error)
		}
		results := execute_parallel_readonly_workspace_tools(app, root, session_id, calls,
			skill_context.tool_policy, mut read_paths, loop_skip_notes)
		if context_error := turn_context_error(mut turn_ctx) {
			return error(context_error)
		}
		return results
	}
	mut results := []string{len: calls.len}
	mut index := 0
	for index < calls.len {
		if context_error := turn_context_error(mut turn_ctx) {
			return error(context_error)
		}
		end := agent_tool_readonly_run_end(calls, index)
		if end > index {
			start := index
			index = end
			if index - start > 1 {
				batch_results := execute_parallel_readonly_workspace_tools(app, root, session_id,
					calls[start..index], skill_context.tool_policy, mut read_paths,
					loop_skip_notes)
				for offset, result in batch_results {
					results[start + offset] = result
				}
				if context_error := turn_context_error(mut turn_ctx) {
					return error(context_error)
				}
				continue
			}
			index = start
		}
		call := calls[index]
		if note := loop_skip_notes[call.id] {
			results[index] = note
			index++
			continue
		}
		if identity := workspace_read_identity_from_call(call) {
			if skill_context.tool_policy.allows(call.function.name) {
				path := workspace_read_path_from_call(call) or { '' }
				if read_paths[identity] || read_paths[json2.encode[[]string]([path])] {
					results[index] = duplicate_workspace_read_note(path)
					index++
					continue
				}
			}
		}
		// Edits, shell, and MCP may change workspace contents. A denied Skill
		// read is handled below without entering the duplicate-read cache.
		if skill_context.tool_policy.allows(call.function.name)
			&& agent_tool_may_mutate_workspace(call.function.name, mcp_bindings) {
			read_paths.clear()
		}
		execution_result := execute_agent_tool_if_allowed_with_status(app, mut turn_ctx, root,
			session_id, operation_id, call, mut skill_context, mcp_bindings,
			mut mcp_connections, policy)!
		results[index] = sanitize_agent_tool_result(execution_result.result)
		if identity := workspace_read_identity_from_call(call) {
			if execution_result.workspace_read_succeeded {
				read_paths[identity] = true
			}
		}
		index++
	}
	return results
}

struct AgentToolError {
	error string
}

fn agent_tool_result_search_paths(result string) []string {
	search := json2.decode[WorkspaceSearchResult](result) or { return []string{} }
	mut paths := []string{cap: search.matches.len}
	for search_match in search.matches {
		if search_match.path !in paths {
			paths << search_match.path
		}
	}
	return paths
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

fn prepare_agent_workspace_edit(root string, arguments map[string]json2.Any) !WorkspaceEditDraft {
	path := string_tool_argument(arguments, 'path')!
	if 'content' in arguments {
		if arguments.len != 2 {
			return error('complete content cannot be combined with replacement arguments')
		}
		content := string_tool_argument(arguments, 'content')!
		return prepare_workspace_edit(root, path, content)
	}
	if arguments.len != 3 || 'old_text' !in arguments || 'new_text' !in arguments {
		return error('provide either complete content or both old_text and new_text')
	}
	old_text := string_tool_argument(arguments, 'old_text')!
	new_text := string_tool_argument(arguments, 'new_text')!
	return prepare_workspace_replacement_edit(root, path, old_text, new_text)
}

fn agent_tool_result_applied_workspace_effect(call ProviderToolCall, result string) bool {
	match call.function.name {
		'workspace_propose_file_edit' {
			edit := json2.decode[AgentWorkspaceEditResult](result) or { return false }
			return edit.note.starts_with('Applied by graduated execution policy')
		}
		'workspace_propose_shell_command' {
			command := json2.decode[ShellCommandSummary](result) or { return false }
			return command.status == 'succeeded' && command.exit_code == 0
		}
		else {
			return false
		}
	}
}

fn agent_tool_result_workspace_edit_proposal_succeeded(call ProviderToolCall, result string) bool {
	if call.function.name != 'workspace_propose_file_edit' {
		return false
	}
	edit := json2.decode[AgentWorkspaceEditResult](result) or { return false }
	return edit.id.len > 0 && edit.path.len > 0 && edit.note.len > 0
}

fn agent_tool_result_workspace_edit_failed(call ProviderToolCall, result string) bool {
	if call.function.name != 'workspace_propose_file_edit' {
		return false
	}
	tool_error := json2.decode[AgentToolError](result) or { return false }
	return tool_error.error.len > 0 && !tool_error.error.contains('edit was applied')
}

fn agent_tool_result_workspace_edit_recoverable(call ProviderToolCall, result string,
	tool_was_skipped bool) bool {
	return !tool_was_skipped && agent_tool_result_workspace_edit_failed(call, result)
}

fn agent_tool_result_workspace_edit_effect_uncertain(call ProviderToolCall, result string) bool {
	if call.function.name != 'workspace_propose_file_edit' {
		return false
	}
	tool_error := json2.decode[AgentToolError](result) or { return false }
	return tool_error.error.contains('edit was applied')
}

fn agent_tool_result_pending_workspace_effect_review(call ProviderToolCall, result string) bool {
	match call.function.name {
		'workspace_propose_file_edit' {
			edit := json2.decode[AgentWorkspaceEditResult](result) or { return false }
			return edit.note == 'Stored for human review. The file has not been changed.'
		}
		'workspace_propose_shell_command' {
			command := json2.decode[AgentShellCommandResult](result) or { return false }
			return command.note == 'Stored for human review. No command was executed.'
		}
		else {
			return false
		}
	}
}

fn workspace_agent_tools() []AgentToolDefinition {
	return [
		AgentToolDefinition{
			name:        'workspace_list_files'
			description: 'List up to 500 regular files in the current workspace or a workspace-relative directory. Provide path to list a subdirectory or a single file; omit path or use . to list the workspace root. Common generated and dependency directories and symbolic links are skipped.'
			parameters:  ToolParameters{
				properties: {
					'path': ToolParameter{ type: 'string', description: 'Optional workspace-relative directory or file to list; omit it or use . for the workspace root.' }
				}
				required:   []string{}
			}
		},
		AgentToolDefinition{
			name:        'workspace_read_file'
			description: 'Read one UTF-8 text file inside the current workspace (maximum file size 512000 bytes). Omit line range arguments to read the whole file; otherwise provide start_line and line_count to read a bounded, one-based excerpt. Ranged reads return at most 200 lines and 32000 bytes with line numbers.'
			parameters:  ToolParameters{
				properties: {
					'path':       ToolParameter{
						type:        'string'
						description: 'Relative file path inside the workspace.'
					}
					'start_line': ToolParameter{ type: 'integer', description: 'One-based first line to return. Requires line_count or end_line.' }
					'line_count': ToolParameter{ type: 'integer', description: 'Number of lines to return, from 1 to 200. Requires start_line; do not combine with end_line.' }
					'end_line':   ToolParameter{ type: 'integer', description: 'One-based last line to return, inclusive. Requires start_line and may span at most 200 lines; do not combine with line_count.' }
				}
				required:   ['path']
			}
		},
		AgentToolDefinition{
			name:        'workspace_search'
			description: 'Search bounded workspace files for a case-sensitive literal phrase. If it has no exact matches, the search combines matches from up to four longest query terms and ranks lines matching more terms first.'
			parameters:  ToolParameters{
				properties: {
					'query': ToolParameter{
						type:        'string'
						description: 'Literal phrase or a few distinctive terms; exact phrase is tried first, then up to four longest terms are combined and ranked. Maximum 256 UTF-8 bytes.'
					}
				}
				required:   ['query']
			}
		},
		AgentToolDefinition{
			name:        'subagent_run'
			description: 'Start one focused child task with a trusted built-in role. The child runs asynchronously in an isolated workspace and returns a durable run ID immediately. Use subagent_wait to collect its terminal result. Optionally select a configured provider and model together; otherwise inherit this conversation operation model.'
			parameters:  ToolParameters{
				properties: {
					'agent_id': ToolParameter{ type: 'string', description: 'Trusted built-in role: explorer, reviewer, or implementer. Implementer can edit only its isolated worktree under the inherited execution policy; parent integration always requires explicit review.' }
					'task':     ToolParameter{ type: 'string', description: 'Focused task brief, at most 8192 UTF-8 bytes.' }
					'provider': ToolParameter{ type: 'string', description: 'Optional configured provider ID. Must be supplied together with model.' }
					'model':    ToolParameter{ type: 'string', description: 'Optional model ID configured for the selected provider. Must be supplied together with provider.' }
				}
				required:   ['agent_id', 'task']
			}
		},
		AgentToolDefinition{
			name:        'subagent_wait'
			description: 'Wait up to 30 seconds for one child run belonging to this conversation and parent operation. Returns the persisted terminal result if available, otherwise an explicit running or wait-interrupted status. Waiting never cancels the child.'
			parameters:  ToolParameters{
				properties: {
					'run_id':  ToolParameter{ type: 'string', description: 'Durable run ID returned by subagent_run.' }
					'wait_ms': ToolParameter{ type: 'integer', description: 'Optional bounded wait from 0 to 30000 milliseconds; defaults to 10000.' }
				}
				required:   ['run_id']
			}
		},
		AgentToolDefinition{
			name:        'workspace_propose_file_edit'
			description: 'Propose a change to one UTF-8 file in the current workspace. Prefer old_text and new_text for a focused replacement; old_text must match the existing file exactly once, and all other file content is preserved. For a broader change, provide the complete file as content instead. This never writes the file unless an explicit autonomous execution policy is active; otherwise the user must inspect and approve the stored diff.'
			parameters:  ToolParameters{
				properties: {
					'path':     ToolParameter{
						type:        'string'
						description: 'Relative path to an existing file or a new file whose parent directory already exists.'
					}
					'content':  ToolParameter{
						type:        'string'
						description: 'Complete proposed UTF-8 file text for a broader edit. Do not use for a focused replacement; use old_text and new_text instead.'
					}
					'old_text': ToolParameter{
						type:        'string'
						description: 'Exact existing UTF-8 text to replace. Must match exactly once in the current file.'
					}
					'new_text': ToolParameter{
						type:        'string'
						description: 'UTF-8 replacement text for the exact old_text match. All other file bytes are preserved.'
					}
				}
				required:   ['path']
			}
		},
		AgentToolDefinition{
			name:        'workspace_propose_shell_command'
			description: 'Propose one single-line shell command for the user to inspect and explicitly approve. This tool never executes commands. Execution uses /bin/sh on POSIX or COMSPEC on Windows with the server OS user identity. Approved commands default to a platform OS sandbox: Bubblewrap on Linux, Seatbelt on macOS, or AppContainer + Job Object on Windows; network is isolated unless VEASEL_SHELL_SANDBOX_NETWORK=allow. Unset/invalid VEASEL_SHELL_SANDBOX fails closed if the platform backend is unavailable. Explicit auto permits unsandboxed fallback and off disables wrapping; those modes inherit the server environment. The Windows wrap is not Codex WFP/LPAC. Capabilities shell.sandbox.bubblewrap, shell.sandbox.seatbelt, and shell.sandbox.windows are true only when that platform will actually wrap approved commands. Execution is never replayed automatically after a restart. Use only when the requested task requires a shell side effect.'
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

fn agent_tools_for_skill_context(tools []AgentToolDefinition, skill_context SessionSkillContext) []AgentToolDefinition {
	if skill_context.resource_access.len == 0 {
		return tools
	}
	mut turn_tools := tools.clone()
	turn_tools << restrict_agent_tools(agent_skill_resource_tools(), skill_context.tool_policy)
	return turn_tools
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
	session_id string, operation_id string, request_deadline time.Time, mut skill_context SessionSkillContext,
	on_text_delta ProviderTextDeltaFn, mut trace_steps []ATIFStep, collect_trace bool,
	policy ExecutionPolicyTurn, provider_pool ProviderPool) !AgentTraceResult {
	return app.run_workspace_agent_turn_with_model_override(mut turn_ctx, mut messages, root,
		session_id, operation_id, request_deadline, mut skill_context, on_text_delta,
		mut trace_steps, collect_trace, policy, provider_pool, none)
}

fn (app &App) run_workspace_agent_turn_with_model_override(mut turn_ctx vcontext.Context, mut messages []ChatMessage, root string,
	session_id string, operation_id string, request_deadline time.Time, mut skill_context SessionSkillContext,
	on_text_delta ProviderTextDeltaFn, mut trace_steps []ATIFStep, collect_trace bool,
	policy ExecutionPolicyTurn, provider_pool ProviderPool,
	model_config_override ?ModelConfig) !AgentTraceResult {
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
	tools << mcp_tools
	tools = restrict_agent_tools(tools, skill_context.tool_policy)
	tools = restrict_agent_tools_for_execution_policy(tools, policy)
	mut tool_calls := 0
	mut result_bytes := 0
	mut seen_tool_call_ids := map[string]bool{}
	mut read_paths := map[string]bool{}
	mut workspace_search_performed := false
	mut workspace_read_after_search := false
	mut workspace_search_match_paths := map[string]bool{}
	mut loop_tracker := AgentToolLoopTracker{}
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
	mut followthrough_retries := 0
	mut edit_proposal_attempted := false
	mut failed_edit_proposals := 0
	mut workspace_effect_applied := false
	mut workspace_effect_pending_review := false
	code_change_request_text := agent_latest_user_request_text(messages)
	code_change_request := explicit_agent_code_change_request(messages)
	verification_required := explicit_agent_verification_request(messages)
	mut verification_succeeded := false
	mut verification_failed := false
	mut verification_prompt_issued := false
	mut read_only_tool_calls := 0
	mut exploration_nudged := false
	for round in 0 .. max_agent_tool_rounds {
		if context_error := turn_context_error(mut turn_ctx) {
			return error(context_error)
		}
		app.apply_session_compaction_if_due(mut turn_ctx, mut messages, session_id, operation_id,
			request_deadline, provider_pool, model_config_override)!
		if agent_context_bytes(messages) > agent_context_byte_limit() {
			return error('agent context size limit reached')
		}
		followthrough_tools := agent_tools_for_skill_context(tools, skill_context)
		mut turn_tools := followthrough_tools.clone()
		turn_tools = agent_code_change_tools_for_progress(turn_tools, code_change_request,
			edit_proposal_attempted, read_paths.len, workspace_search_performed,
			workspace_read_after_search,
			followthrough_retries > 0)
		if code_change_request && failed_edit_proposals > max_agent_code_change_edit_recovery_attempts {
			edit_proposal_attempted = true
		}
		turn_tools = agent_code_change_tools_after_edit_failures(turn_tools, code_change_request,
			failed_edit_proposals)
		turn_tools = agent_code_change_verification_tools(turn_tools, verification_required,
			workspace_effect_applied, verification_succeeded, verification_failed)
		buffer_provider_text := (code_change_request && !workspace_effect_applied)
			|| agent_code_change_followthrough_retry_available(code_change_request, followthrough_tools,
				followthrough_retries, edit_proposal_attempted, request_deadline)
			|| (verification_required && workspace_effect_applied && !verification_succeeded)
		mut buffered_text := ''
		stream_text_delta := if buffer_provider_text {
			fn [mut buffered_text] (delta string) ! {
				buffered_text += delta
			}
		} else {
			on_text_delta
		}
		output := app.complete_agent_with_model_override(mut turn_ctx, session_id, messages, turn_tools,
			code_change_request && (!edit_proposal_attempted || (verification_required
				&& workspace_effect_applied && !verification_succeeded && !verification_failed)),
			stream_text_delta, request_deadline,
			provider_pool, model_config_override) or {
			if buffer_provider_text && buffered_text.len > 0
				&& !agent_discard_buffered_text_on_provider_error(code_change_request) {
				on_text_delta(buffered_text) or { return err }
			}
			return err
		}
		if has_provider_usage_data(output.usage) {
			trace_usage = add_provider_usage(trace_usage, output.usage)
		}
		if output.tool_calls.len == 0 {
			if output.content.trim_space().len == 0 {
				return error('model returned no final response')
			}
			if agent_code_change_followthrough_retry_available(code_change_request, followthrough_tools, followthrough_retries,
				edit_proposal_attempted, request_deadline) {
				messages << ChatMessage{
					role:    'assistant'
					content: output.content
				}
				messages << ChatMessage{
					role:    'user'
					content: if read_paths.len > 0 {
						agent_code_change_retry_after_read_prompt
					} else if followthrough_retries == 0 {
						agent_code_change_retry_prompt
					} else {
						agent_code_change_retry_after_no_read_prompt
					}
				}
				if collect_trace {
					trace_steps << ATIFStep{
						step_id:    trace_steps.len + 1
						source:     'agent'
						model_name: output.model
						message:    output.content
					}
					trace_steps << ATIFStep{
						step_id: trace_steps.len + 1
						source:  'user'
						message: messages.last().content
					}
				}
				followthrough_retries++
				continue
			}
			final_output := CompletionOutput{
				provider:         output.provider
				model:            output.model
				content:          agent_final_response_for_verification(agent_final_response_for_execution_policy(output.content, code_change_request,
					policy, workspace_effect_applied, workspace_effect_pending_review),
					verification_required, workspace_effect_applied, verification_succeeded)
				provider_context: output.provider_context
				usage:            output.usage
			}
			if buffer_provider_text {
				on_text_delta(final_output.content)!
			}
			if collect_trace {
				trace_steps << ATIFStep{
					step_id:    trace_steps.len + 1
					source:     'agent'
					model_name: final_output.model
					message:    final_output.content
				}
			}
			return AgentTraceResult{
				output: final_output
				steps:  trace_steps
				usage:  trace_usage
			}
		}
		if tool_calls + output.tool_calls.len > max_agent_tool_calls {
			if buffer_provider_text && buffered_text.len > 0 {
				on_text_delta(buffered_text)!
			}
			// Over-budget turns must still produce a durable reply: ask the model
			// for the budget summary instead of failing the whole operation.
			return app.finish_with_tool_budget_summary(mut turn_ctx, session_id, messages, output,
				on_text_delta, mut trace_steps, mut trace_usage, collect_trace, request_deadline,
				provider_pool, model_config_override)
		}
		if round == max_agent_tool_rounds - 1 {
			if buffer_provider_text && buffered_text.len > 0 {
				on_text_delta(buffered_text)!
			}
			return app.finish_with_tool_budget_summary(mut turn_ctx, session_id, messages, output, on_text_delta,
				mut trace_steps, mut trace_usage, collect_trace, request_deadline, provider_pool,
				model_config_override)
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
			if agent_tool_is_readonly_exploration(call.function.name) {
				read_only_tool_calls++
			}
		}
		if buffer_provider_text && buffered_text.len > 0 {
			on_text_delta(buffered_text)!
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
		mut loop_skip_notes := map[string]string{}
		mut loop_warnings := []string{cap: output.tool_calls.len}
		for call in output.tool_calls {
			if !agent_tool_available_in_turn(call.function.name, turn_tools) {
				loop_skip_notes[call.id] = encode_agent_tool_error('Tool is not available in the current progress phase.')
				continue
			}
			match loop_tracker.inspect(call) {
				.warning {
					loop_warnings << agent_tool_loop_warning(call)
				}
				.stop {
					loop_skip_notes[call.id] = agent_tool_loop_stop_note(call)
				}
				.ok {}
			}
			if call.id in loop_skip_notes {
				continue
			}
			if call.function.name == 'workspace_search'
				&& !agent_workspace_search_call_relevant(call, code_change_request,
					code_change_request_text) {
				loop_skip_notes[call.id] = encode_agent_tool_error('Search terms do not match the explicit code-change request. Search with a distinctive term from that request, such as mobile or sidebar.')
				continue
			}
			if call.function.name == 'workspace_read_file'
				&& !agent_workspace_read_call_allowed(call, code_change_request,
					workspace_search_performed, workspace_search_match_paths) {
				loop_skip_notes[call.id] = encode_agent_tool_error('For explicit code changes, first run a request-relevant search and read a path returned by it before opening files.')
				continue
			}
		}
		read_paths_before_tool_batch := read_paths.clone()
		search_performed_before_tool_batch := workspace_search_performed
		tool_results := execute_agent_tool_batch(app, mut turn_ctx, root, session_id, operation_id,
			output.tool_calls, mut skill_context, mcp_bindings, mut mcp_connections, policy,
			mut read_paths, loop_skip_notes)!
		for index, call in output.tool_calls {
			if index < tool_results.len {
				tool_result := tool_results[index]
				if agent_tool_result_workspace_edit_proposal_succeeded(call, tool_result) {
					edit_proposal_attempted = true
				}
				if agent_tool_result_workspace_edit_recoverable(call, tool_result,
					call.id in loop_skip_notes) {
					failed_edit_proposals++
					if failed_edit_proposals <= max_agent_code_change_edit_recovery_attempts {
						// Permit one fresh read after a validation failure. Keep the prior
						// relevant search paths, but require the model to read a match again.
						read_paths = map[string]bool{}
						workspace_read_after_search = false
					}
				} else if agent_tool_result_workspace_edit_effect_uncertain(call, tool_result) {
					// Never retry a proposal when the write may already have happened.
					edit_proposal_attempted = true
				}
				if call.function.name == 'workspace_search'
					&& agent_workspace_search_call_relevant(call, code_change_request,
						code_change_request_text) {
					for path in agent_tool_result_search_paths(tool_result) {
						workspace_search_match_paths[path] = true
						workspace_search_performed = true
						if agent_workspace_file_was_read(path, read_paths) {
							workspace_read_after_search = true
						}
					}
				}
				if call.function.name == 'workspace_read_file' && search_performed_before_tool_batch
					&& agent_workspace_read_succeeded_since(call, read_paths_before_tool_batch,
						read_paths) {
					if path := workspace_read_path_from_call(call) {
						workspace_read_after_search = workspace_read_after_search
							|| path in workspace_search_match_paths
					}
				}
				if verification_required && workspace_effect_applied
					&& call.function.name == 'workspace_propose_shell_command' {
					verification := json2.decode[ShellCommandSummary](tool_result) or {
						ShellCommandSummary{ status: 'failed', exit_code: -1 }
					}
					verification_succeeded = verification.status == 'succeeded'
						&& verification.exit_code == 0
					verification_failed = !verification_succeeded
					verification_prompt_issued = false
				}
				workspace_effect_applied = workspace_effect_applied
					|| agent_tool_result_applied_workspace_effect(call, tool_result)
				if verification_required && call.function.name == 'workspace_propose_file_edit'
					&& agent_tool_result_applied_workspace_effect(call, tool_result) {
					verification_succeeded = false
					verification_failed = false
					verification_prompt_issued = false
				}
				workspace_effect_pending_review = workspace_effect_pending_review
					|| agent_tool_result_pending_workspace_effect_review(call, tool_result)
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
		if code_change_request && failed_edit_proposals > 0
			&& failed_edit_proposals <= max_agent_code_change_edit_recovery_attempts {
			messages << ChatMessage{
				role:    'user'
				content: agent_code_change_edit_recovery_prompt
			}
			if collect_trace {
				trace_steps << ATIFStep{
					step_id: trace_steps.len + 1
					source:  'user'
					message: agent_code_change_edit_recovery_prompt
				}
			}
		}
		if collect_trace {
			trace_steps[trace_steps.len - 1].observation = ATIFObservation{
				results: trace_observations
			}
		}
		append_agent_tool_loop_warnings(mut messages, mut trace_steps, loop_warnings,
			collect_trace)
		if verification_required && workspace_effect_applied && !verification_succeeded
			&& !verification_prompt_issued {
			verification_prompt := if verification_failed {
				agent_code_change_verification_failure_prompt
			} else {
				agent_code_change_verification_prompt
			}
			messages << ChatMessage{
				role:    'user'
				content: verification_prompt
			}
			if collect_trace {
				trace_steps << ATIFStep{
					step_id: trace_steps.len + 1
					source:  'user'
					message: verification_prompt
				}
			}
			verification_prompt_issued = true
		}
		if agent_code_change_exploration_nudge_available(code_change_request, followthrough_tools,
			read_only_tool_calls, exploration_nudged, edit_proposal_attempted, request_deadline) {
			messages << ChatMessage{
				role:    'user'
				content: agent_code_change_exploration_nudge
			}
			if collect_trace {
				trace_steps << ATIFStep{
					step_id: trace_steps.len + 1
					source:  'user'
					message: agent_code_change_exploration_nudge
				}
			}
			exploration_nudged = true
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

fn (app &App) finish_with_tool_budget_summary(mut turn_ctx vcontext.Context, session_id string,
	messages []ChatMessage,
	blocked CompletionOutput, on_text_delta ProviderTextDeltaFn, mut trace_steps []ATIFStep,
	mut trace_usage ProviderUsage, collect_trace bool, request_deadline time.Time, provider_pool ProviderPool,
	model_config_override ?ModelConfig) !AgentTraceResult {
	summary_messages := messages_for_tool_budget_summary(messages, blocked.tool_calls)
	if agent_context_bytes(summary_messages) > agent_context_byte_limit() {
		return error('agent tool round limit reached')
	}
	boundary := tool_round_text_boundary(blocked.content)
	if boundary.len > 0 {
		on_text_delta(boundary)!
	}
	summary := app.complete_agent_with_model_override(mut turn_ctx, session_id, summary_messages, [],
		false, on_text_delta, request_deadline, provider_pool, model_config_override)!
	if has_provider_usage_data(summary.usage) {
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
	if call.function.name == 'subagent_run' {
		return app.execute_subagent_run(mut turn_ctx, session_id, operation_id, call,
			policy, skill_context.tool_policy)
	}
	if call.function.name == 'subagent_wait' {
		return app.execute_subagent_wait(mut turn_ctx, session_id, operation_id, call)
	}
	if tool_class in ['edit', 'shell'] {
		decision := decide_execution_permission(policy.mode, tool_class, policy.interactive,
			fail_closed_shell_sandbox_ready())
		match decision {
			.allow {
				return execute_autonomous_workspace_agent_tool(app, mut turn_ctx, root, session_id, call)
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

fn execute_agent_tool_if_allowed_with_status(app &App, mut turn_ctx vcontext.Context, root string,
	session_id string, operation_id string, call ProviderToolCall,
	mut skill_context SessionSkillContext, mcp_bindings map[string]PluginMCPToolBinding,
	mut mcp_connections []PluginMCPConnection, policy ExecutionPolicyTurn) !AgentToolExecutionResult {
	if call.function.name == 'workspace_read_file' {
		if !skill_context.tool_policy.allows(call.function.name) {
			return AgentToolExecutionResult{
				result: encode_agent_tool_error('Tool is not available under the active Agent Skill tool restrictions.')
			}
		}
		return execute_workspace_read_file_tool(root, call)
	}
	return AgentToolExecutionResult{
		result: execute_agent_tool_if_allowed(app, mut turn_ctx, root, session_id, operation_id,
			call, mut skill_context, mcp_bindings, mut mcp_connections, policy)!
	}
}

fn execute_autonomous_workspace_agent_tool(app &App, mut turn_ctx vcontext.Context,
	root string, session_id string, call ProviderToolCall) string {
	if call.function.name == 'workspace_propose_file_edit' {
		tool_arguments := json2.decode[map[string]json2.Any](call.function.arguments) or {
			return encode_agent_tool_error('Tool arguments must be a JSON object.')
		}
		draft := prepare_agent_workspace_edit(root, tool_arguments) or {
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
		result := run_approved_shell_command_with_context(mut turn_ctx, root, approved, true)
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
// active_model_token_budget resolves the curated context window for the
// active model plus the configured output reserve held back from it. Unknown
// models return a zero window so no budget is invented for them.
fn (app &App) active_model_token_budget() (int, int) {
	return app.active_model_token_budget_with_model_override(none)
}

fn (app &App) active_model_token_budget_with_model_override(model_config_override ?ModelConfig) (int, int) {
	config := if model_config_override != none {
		model_config_override
	} else {
		app.model_config() or { return 0, 0 }
	}
	return active_model_context_window(config), config.max_output_tokens
}

// active_model_context_window accepts an explicit operator-supplied window for
// custom/local models whose limit is not in the curated model schedule. This
// takes precedence because a provider's runtime limit can be lower than the
// model's advertised maximum (for example, Ollama num_ctx).
fn active_model_context_window(config ModelConfig) int {
	if raw := os.getenv_opt('VEASEL_MODEL_CONTEXT_TOKENS') {
		if configured := parse_model_context_window(raw) {
			return configured
		}
	}
	return model_context_tokens(config.provider, config.model) or { 0 }
}

fn parse_model_context_window(raw string) ?int {
	value := raw.trim_space()
	if value.len == 0 || value.len > 7 {
		return none
	}
	for digit in value {
		if digit < `0` || digit > `9` {
			return none
		}
	}
	tokens := value.int()
	if tokens < 128 || tokens > 1_048_576 {
		return none
	}
	return tokens
}

fn (app &App) apply_session_compaction_if_due(mut turn_ctx vcontext.Context, mut messages []ChatMessage,
	session_id string, operation_id string, request_deadline time.Time, provider_pool ProviderPool,
	model_config_override ?ModelConfig) ! {
	mode := session_compaction_summarizer_mode()
	context_tokens, reserved_output_tokens := app.active_model_token_budget_with_model_override(model_config_override)
	result := match mode {
		'native' {
			compact_session_messages_with_summarizer(messages, 'native', native_session_compaction_summarizer,
				context_tokens, reserved_output_tokens)
		}
		'llm' {
			app.compact_session_messages_with_llm_summarizer(mut turn_ctx, session_id, messages,
				context_tokens, reserved_output_tokens, request_deadline, provider_pool,
				model_config_override)
		}
		else {
			compact_session_messages(messages, context_tokens, reserved_output_tokens)
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
	session_id string, messages []ChatMessage, model_context_tokens int,
	reserved_output_tokens int, request_deadline time.Time, provider_pool ProviderPool,
	model_config_override ?ModelConfig) SessionCompactionResult {
	bytes_before := agent_context_bytes(messages)
	due, reason := session_compaction_due(messages, model_context_tokens, reserved_output_tokens)
	if !due {
		return compaction_result_unchanged(messages, bytes_before, '')
	}
	first := first_conversation_index(messages)
	keep_bytes := compaction_keep_bytes_for_window(model_context_tokens, reserved_output_tokens)
	cut := find_compaction_cut(messages, keep_bytes, reason)
	if cut <= first || cut >= messages.len {
		return compaction_result_unchanged(messages, bytes_before, reason)
	}
	older := messages[first..cut]
	if older.len == 0 {
		return compaction_result_unchanged(messages, bytes_before, reason)
	}
	preferred := app.llm_session_compaction_summary(mut turn_ctx, session_id, older, bytes_before,
		reason, request_deadline, provider_pool, model_config_override) or {
		return apply_extractive_compaction(messages, bytes_before, reason, 'llm_fallback_extractive',
			ProviderUsage{}, keep_bytes)
	}
	return compact_session_messages_preferring(messages, 'llm', preferred, model_context_tokens,
		reserved_output_tokens)
}

fn (app &App) llm_session_compaction_summary(mut turn_ctx vcontext.Context, session_id string,
	older []ChatMessage,
	bytes_before int, reason string, request_deadline time.Time, provider_pool ProviderPool,
	model_config_override ?ModelConfig) !SessionCompactionSummarizerOutput {
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
	output := app.complete_agent_with_model_override(mut turn_ctx, session_id, prompt, [],
		false, ignore_provider_text_delta, request_deadline, provider_pool, model_config_override)!
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
			if tool_arguments.len > 1 {
				return encode_agent_tool_error('This tool does not accept arguments.')
			}
			path := if tool_arguments.len == 0 {
				'.'
			} else {
				string_tool_argument(tool_arguments, 'path') or {
					return encode_agent_tool_error('The workspace directory path must be a string.')
				}
			}
			files := workspace_files_from(root, path, max_workspace_list_results) or {
				return encode_agent_tool_error('Workspace files could not be listed.')
			}
			json2.encode[WorkspaceFileList](files)
		}
		'workspace_read_file' {
			execute_workspace_read_file_tool(root, call).result
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
			draft := prepare_agent_workspace_edit(root, tool_arguments) or {
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

fn execute_workspace_read_file_tool(root string, call ProviderToolCall) AgentToolExecutionResult {
	tool_arguments := json2.decode[map[string]json2.Any](call.function.arguments) or {
		return AgentToolExecutionResult{
			result: encode_agent_tool_error('Tool arguments must be a JSON object.')
		}
	}
	path := string_tool_argument(tool_arguments, 'path') or {
		return AgentToolExecutionResult{
			result: encode_agent_tool_error('A relative path string is required.')
		}
	}
	start, count := workspace_read_range_arguments(tool_arguments) or {
		return AgentToolExecutionResult{
			result: encode_agent_tool_error(err.msg())
		}
	}
	if start > 0 {
		range := workspace_file_range(root, path, start, count) or {
			return AgentToolExecutionResult{
				result: encode_agent_tool_error('The workspace file range is invalid or unavailable.')
			}
		}
		return AgentToolExecutionResult{
			result:                   json2.encode[WorkspaceFileRange](range)
			workspace_read_succeeded: true
		}
	}
	file := workspace_file(root, path) or {
		return AgentToolExecutionResult{
			result: encode_agent_tool_error('The workspace file is invalid or unavailable.')
		}
	}
	return AgentToolExecutionResult{
		result:                   json2.encode[WorkspaceFileContent](file)
		workspace_read_succeeded: true
	}
}

fn string_tool_argument(arguments map[string]json2.Any, key string) !string {
	value := arguments[key] or { return error('required string argument is missing') }
	if value !is string {
		return error('tool argument must be a string')
	}
	return value as string
}
