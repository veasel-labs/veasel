module main

import json2
import net.http
import os
import strings
import time
import uuid

const max_headless_prompt_bytes = max_chat_input_bytes
const max_headless_timeout = 24 * time.hour
const default_headless_timeout = 30 * time.minute
const headless_request_timeout = 5 * time.second
const headless_poll_interval = 250 * time.millisecond

struct HeadlessRunOptions {
mut:
	prompt     string
	workspace  string
	session_id string
	trace_file string
	json       bool
	autonomous bool
	timeout    time.Duration = default_headless_timeout
}

struct HeadlessRunResult {
pub:
	session_id     string
	operation_id   string
	status         string
	provider       string @[omitempty]
	model          string @[omitempty]
	response       string @[omitempty]
	error          string @[omitempty]
	trace_file     string @[omitempty]
	input_tokens   i64    @[omitempty]
	output_tokens  i64    @[omitempty]
	usage_reported bool   @[omitempty]
}

fn parse_headless_run_args(args []string, cwd string) !HeadlessRunOptions {
	mut options := HeadlessRunOptions{
		workspace: cwd
	}
	mut index := 0
	for index < args.len {
		arg := args[index]
		match arg {
			'--prompt', '-p' {
				index++
				if index >= args.len || options.prompt.len > 0 {
					return error('run expects one non-empty --prompt value')
				}
				options.prompt = args[index]
			}
			'--workspace', '-w' {
				index++
				if index >= args.len || args[index].trim_space().len == 0 {
					return error('--workspace expects a directory path')
				}
				options.workspace = args[index]
			}
			'--session' {
				index++
				if index >= args.len || options.session_id.len > 0 {
					return error('--session expects one session UUID')
				}
				parsed := uuid.parse(args[index]) or { return error('--session must be a valid UUID') }
				if parsed == uuid.nil_uuid {
					return error('--session must be a non-nil UUID')
				}
				options.session_id = parsed.str()
			}
			'--trace-file' {
				index++
				if index >= args.len || args[index].trim_space().len == 0 || options.trace_file.len > 0 {
					return error('--trace-file expects one output path')
				}
				options.trace_file = args[index]
			}
			'--timeout' {
				index++
				if index >= args.len {
					return error('--timeout expects seconds from 1 to 86400')
				}
				seconds := args[index].int()
				if seconds < 1 || seconds > int(max_headless_timeout / time.second) {
					return error('--timeout expects seconds from 1 to 86400')
				}
				options.timeout = seconds * time.second
			}
			'--json' {
				options.json = true
			}
			'--autonomous' {
				options.autonomous = true
			}
			'--help', '-h' {
				return error('help')
			}
			else {
				return error('unknown run option: ${arg}')
			}
		}
		index++
	}
	if options.prompt.trim_space().len == 0 {
		return error('run requires a non-empty --prompt')
	}
	if options.prompt.len > max_headless_prompt_bytes {
		return error('prompt exceeds the ${max_headless_prompt_bytes}-byte limit')
	}
	return options
}

fn headless_json_request(port int, method http.Method, path string, data string,
	prefer_async bool, operation_id string) !http.Response {
	mut header := http.new_header()
	header.set(.content_type, 'application/json')
	header.set(.accept, 'application/json')
	if prefer_async {
		header.set_custom('Prefer', 'respond-async')!
	}
	if operation_id.len > 0 {
		header.set_custom('X-Veasel-Operation-ID', operation_id)!
	}
	return http.fetch(
		url:           'http://127.0.0.1:${port}${path}'
		method:        method
		data:          data
		header:        header
		read_timeout:  headless_request_timeout
		write_timeout: headless_request_timeout
		// V's HTTP client treats zero retries as zero attempts. Keep one attempt;
		// message submission carries an operation UUID to prevent duplicate work.
		max_retries:   1
	)
}

fn headless_session_title(prompt string) string {
	first_line := prompt.all_before('\n').trim_space()
	if first_line.len == 0 {
		return 'Veasel Code task'
	}
	mut title := strings.new_builder(200)
	mut title_bytes := 0
	for character in first_line.runes() {
		encoded := character.str()
		if title_bytes + encoded.len > 200 {
			break
		}
		title.write_string(encoded)
		title_bytes += encoded.len
	}
	return title.str()
}

fn ensure_headless_session(port int, mut options HeadlessRunOptions) ! {
	if options.session_id.len == 0 {
		workspace := canonical_workspace_root(options.workspace) or {
			return error('--workspace must resolve to an existing directory')
		}
		title := headless_session_title(options.prompt)
		response := headless_json_request(port, .post, '/v1/sessions', json2.encode(SessionInput{
			title:     title
			directory: workspace
		}), false, '') or {
			return error('unable to create a session: ${err.msg()}')
		}
		if response.status_code != 201 {
			return error('unable to create a session (HTTP ${response.status_code})')
		}
		session := json2.decode[Session](response.body) or {
			return error('server returned an invalid session response')
		}
		options.session_id = session.id
	} else {
		response := headless_json_request(port, .get, '/v1/sessions/${options.session_id}', '', false, '') or {
			return error('unable to load session: ${err.msg()}')
		}
		if response.status_code != 200 {
			return error('session was not found (HTTP ${response.status_code})')
		}
	}
}

fn headless_completed_result(port int, session_id string, operation_id string,
	operation SessionOperation, trace_file string) !HeadlessRunResult {
	result_response := headless_json_request(port, .get,
		'/v1/sessions/${session_id}/operations/${operation_id}/result', '', false, '') or {
		return error('unable to read assistant result: ${err.msg()}')
	}
	if result_response.status_code != 200 {
		return error('unable to read assistant result (HTTP ${result_response.status_code})')
	}
	result := json2.decode[SessionOperationResult](result_response.body) or {
		return error('server returned an invalid assistant result')
	}
	if result.session_id != session_id || result.operation_id != operation_id {
		return error('server returned a result for a different operation')
	}
	if trace_file.len > 0 {
		if result.trajectory.len == 0 {
			return error('server completed the turn without an ATIF trajectory')
		}
		write_atif_trace_file(trace_file, result.trajectory)!
	}
	return HeadlessRunResult{
		session_id:     session_id
		operation_id:   operation_id
		status:         operation.status
		provider:       result.provider
		model:          result.model
		response:       result.content
		trace_file:     if trace_file.len > 0 { trace_file } else { '' }
		input_tokens:   if result.usage_reported { result.input_tokens } else { 0 }
		output_tokens:  if result.usage_reported { result.output_tokens } else { 0 }
		usage_reported: result.usage_reported
	}
}

fn write_atif_trace_file(path string, trajectory string) ! {
	temporary_path := '${path}.tmp-${uuid.new_v4().str()}'
	mut file := os.open_file(temporary_path, 'w', 0o600) or {
		return error('unable to write temporary ATIF trajectory: ${err.msg()}')
	}
	file.write_string(trajectory) or {
		file.close()
		os.rm(temporary_path) or {}
		return error('unable to write temporary ATIF trajectory: ${err.msg()}')
	}
	file.close()
	os.rename(temporary_path, path) or {
		os.rm(temporary_path) or {}
		return error('unable to publish ATIF trajectory at ${path}: ${err.msg()}')
	}
}

fn headless_failed_result(session_id string, operation_id string, message string) HeadlessRunResult {
	return HeadlessRunResult{
		session_id:   session_id
		operation_id: operation_id
		status:       'failed'
		error:        message
	}
}

fn run_headless_task(port int, options HeadlessRunOptions) HeadlessRunResult {
	session_id := options.session_id
	operation_id := uuid.new_v4().str()
	response := headless_json_request(port, .post, '/v1/sessions/${session_id}/messages', json2.encode(ChatMessageInput{
		content:       options.prompt
		collect_trace: options.trace_file.len > 0
		autonomous:    options.autonomous
	}), true, operation_id) or {
		return headless_failed_result(session_id, operation_id, 'unable to start model turn: ${err.msg()}')
	}
	if response.status_code != 202 {
		message := if response.body.len > 0 { response.body } else { 'empty response' }
		return headless_failed_result(session_id, operation_id,
			'unable to start model turn (HTTP ${response.status_code}): ${message}')
	}
	deadline := time.now().add(options.timeout)
	for time.now() < deadline {
		operation_response := headless_json_request(port, .get,
			'/v1/sessions/${session_id}/operations/${operation_id}', '', false, '') or {
			time.sleep(headless_poll_interval)
			continue
		}
		if operation_response.status_code != 200 {
			return headless_failed_result(session_id, operation_id,
				'unable to read model turn state (HTTP ${operation_response.status_code})')
		}
		operation := json2.decode[SessionOperation](operation_response.body) or {
			return headless_failed_result(session_id, operation_id,
				'server returned an invalid operation response')
		}
		match operation.status {
			'completed' {
				return headless_completed_result(port, session_id, operation_id, operation, options.trace_file) or {
					headless_failed_result(session_id, operation_id, err.msg())
				}
			}
			'failed', 'cancelled', 'uncertain' {
				return headless_operation_result(port, session_id, operation_id, operation, options.trace_file)
			}
			'running', 'cancelling' {
				time.sleep(headless_poll_interval)
			}
			else {
				return headless_failed_result(session_id, operation_id,
					'server returned an unknown model turn state')
			}
		}
	}
	cancel_response := headless_json_request(port, .post,
		'/v1/sessions/${session_id}/operations/${operation_id}/cancel', '', false, '') or { http.Response{} }
	// Cancellation races with provider completion. Re-read the durable operation
	// so a just-completed or failed task is not mislabeled as a timeout.
	operation_response := headless_json_request(port, .get,
		'/v1/sessions/${session_id}/operations/${operation_id}', '', false, '') or { http.Response{} }
	if operation_response.status_code == 200 {
		operation := json2.decode[SessionOperation](operation_response.body) or { SessionOperation{} }
		if operation.status == 'completed' {
			return headless_completed_result(port, session_id, operation_id, operation, options.trace_file) or {
				headless_failed_result(session_id, operation_id, err.msg())
			}
		}
		if operation.status in ['failed', 'cancelled', 'uncertain'] {
			return headless_operation_result(port, session_id, operation_id, operation, options.trace_file)
		}
	}
	if cancel_response.status_code != 202 {
		return HeadlessRunResult{
			session_id:   session_id
			operation_id: operation_id
			status:       'timed_out'
			error:        'headless wait limit exceeded; cancellation could not be confirmed, so inspect operation status before retrying'
		}
	}
	return HeadlessRunResult{
		session_id:   session_id
		operation_id: operation_id
		status:       'cancelling'
		error:        'headless wait limit exceeded; cancellation was requested when possible. A provider transport may take time to stop; inspect this session before retrying.'
	}
}

fn headless_operation_result(port int, session_id string, operation_id string,
	operation SessionOperation, trace_file string) HeadlessRunResult {
	mut written_trace := ''
	if trace_file.len > 0 && operation.status in ['failed', 'cancelled'] {
		response := headless_json_request(port, .get,
			'/v1/sessions/${session_id}/operations/${operation_id}/result', '', false, '') or {
			http.Response{}
		}
		if response.status_code == 200 {
			result := json2.decode[SessionOperationResult](response.body) or {
				SessionOperationResult{}
			}
			if result.trajectory.len > 0 {
				write_atif_trace_file(trace_file, result.trajectory) or {
					return HeadlessRunResult{
						session_id:   session_id
						operation_id: operation_id
						status:       'failed'
						error:        'unable to write partial ATIF trajectory: ${err.msg()}'
					}
				}
				written_trace = trace_file
			}
		}
	}
	return HeadlessRunResult{
		session_id:     session_id
		operation_id:   operation_id
		status:         operation.status
		provider:       operation.provider
		model:          operation.model
		error:          operation.error
		trace_file:     written_trace
		input_tokens:   if operation.usage_reported { operation.input_tokens } else { 0 }
		output_tokens:  if operation.usage_reported { operation.output_tokens } else { 0 }
		usage_reported: operation.usage_reported
	}
}

fn format_headless_usage_summary(result HeadlessRunResult) string {
	mut parts := ['session ${result.session_id}']
	if result.provider.len > 0 || result.model.len > 0 {
		parts << '${result.provider} / ${result.model}'
	}
	if result.usage_reported {
		parts << '${result.input_tokens} in · ${result.output_tokens} out'
	}
	return parts.join(' · ')
}

fn print_headless_help() {
	println('Usage: veasel run --prompt <text> [options]\n\nOptions:\n  -p, --prompt <text>   Task instructions (required; max 1 MiB)\n  -w, --workspace <dir> Workspace directory for a new session (default: current directory)\n      --session <uuid>  Continue an existing session instead of creating one\n      --timeout <secs>  Wait limit from 1 to 86400 seconds (default: 1800)\n      --trace-file <p>  Opt in to an ATIF v1.8 trace at this path (private file; partial on failure/cancellation)\n      --json            Emit a machine-readable result\n      --autonomous      Execute edits and shell proposals without review (isolated sandboxes only)\n  -h, --help            Show this help\n\nThe headless command uses the same local server and provider configuration as the TUI.\nBy default, edits, shell commands, and MCP calls still require user approval.\n--autonomous is a dangerous opt-in for disposable, externally sandboxed benchmark\nenvironments only. It requires VEASEL_ALLOW_AUTONOMOUS_EXECUTION=1 when the server starts;\nthat switch does not create a sandbox or restrict arbitrary shell access. Never enable it\non a host workspace or with credentials or data you would not expose to task commands.\nATIF traces contain the model-visible conversation and tool I/O with credentials\nredacted; they may still include private instructions and source code. The owner-only output file is written only when\n--trace-file is explicitly supplied.\nWhen a provider reports token counts, --json includes them and the human summary prints them on stderr.')
}

fn execute_headless_command(port int, args []string) {
	options := parse_headless_run_args(args, os.getwd()) or {
		if err.msg() == 'help' {
			print_headless_help()
			return
		}
		eprintln('veasel: ${err.msg()}')
		print_headless_help()
		exit(2)
	}
	if options.autonomous {
		os.setenv('VEASEL_ALLOW_AUTONOMOUS_EXECUTION', '1', true)
	}
	ensure_backend(port, '') or {
		eprintln('veasel: ${err.msg()}')
		exit(1)
	}
	mut prepared_options := options
	ensure_headless_session(port, mut prepared_options) or {
		if options.json {
			println(json2.encode(HeadlessRunResult{
				session_id: options.session_id
				status:     'failed'
				error:      err.msg()
			}))
		} else {
			eprintln('veasel: ${err.msg()}')
		}
		exit(1)
	}
	result := run_headless_task(port, prepared_options)
	if options.json {
		println(json2.encode(result))
	} else if result.status != 'completed' {
		eprintln('veasel: model turn ${result.status}: ${result.error}\n${format_headless_usage_summary(result)} · operation ${result.operation_id}')
		exit(1)
	} else {
		println(result.response)
		eprintln(format_headless_usage_summary(result))
	}
	if result.status != 'completed' {
		exit(1)
	}
}
