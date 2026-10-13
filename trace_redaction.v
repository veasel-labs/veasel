module main

import json2
import os

const trace_redaction_marker = '[REDACTED]'

// Credential-shaped token prefixes recognized even when the exact value never
// appeared in this process's environment (for example keys pasted into a task,
// printed by a tool, or returned by an MCP server).
const trace_secret_prefixes = ['sk-', 'sk_', 'ghp_', 'gho_', 'ghu_', 'ghs_', 'ghr_', 'github_pat_',
	'xoxb-', 'xoxp-', 'xoxa-', 'xoxs-', 'xoxr-', 'AIza', 'AKIA', 'LLM_', 'eyJ']

// Field names whose values are credentials wherever they appear, in trace text
// assignments (`token = ...`) and in structured tool-call arguments alike.
const trace_secret_field_names = ['api_key', 'api-key', 'api key', 'apikey', 'access_token',
	'access-token', 'access token', 'auth_token', 'auth-token', 'client_secret', 'client-secret',
	'client secret', 'password', 'passwd', 'secret', 'token', 'authorization']

// redact_trace_steps returns a copy of the steps with credentials removed from
// messages, tool-call arguments and observations. This is the only form of a
// trajectory Veasel encodes, stores or writes to a trace file.
fn redact_trace_steps(steps []ATIFStep, secrets []string) []ATIFStep {
	mut safe := []ATIFStep{cap: steps.len}
	for step in steps {
		mut calls := []ATIFToolCall{cap: step.tool_calls.len}
		for call in step.tool_calls {
			calls << ATIFToolCall{
				tool_call_id:  call.tool_call_id
				function_name: call.function_name
				arguments:     redact_trace_arguments(call.arguments, secrets)
			}
		}
		mut observation := step.observation
		if present := observation {
			mut results := []ATIFObservationResult{cap: present.results.len}
			for result in present.results {
				results << ATIFObservationResult{
					source_call_id: result.source_call_id
					content:        redact_trace_text(result.content, secrets)
				}
			}
			observation = ATIFObservation{
				results: results
			}
		}
		safe << ATIFStep{
			step_id:     step.step_id
			source:      step.source
			model_name:  step.model_name
			message:     redact_trace_text(step.message, secrets)
			tool_calls:  calls
			observation: observation
		}
	}
	return safe
}

fn redact_trace_arguments(arguments map[string]json2.Any, secrets []string) map[string]json2.Any {
	mut safe := map[string]json2.Any{}
	for key, value in arguments {
		if key.to_lower() in trace_secret_field_names {
			if value is string {
				safe[key] = json2.Any(trace_redaction_marker)
				continue
			}
		}
		safe[key] = redact_trace_value(value, secrets)
	}
	return safe
}

fn redact_trace_value(value json2.Any, secrets []string) json2.Any {
	return match value {
		string {
			json2.Any(redact_trace_text(value, secrets))
		}
		[]json2.Any {
			json2.Any(value.map(redact_trace_value(it, secrets)))
		}
		map[string]json2.Any {
			json2.Any(redact_trace_arguments(value, secrets))
		}
		else {
			value
		}
	}
}

// trace_secret_env_values returns the values of environment variables whose
// names mark them as credentials. Values shorter than eight bytes are skipped
// so common short settings are never treated as secrets. Longest values come
// first so a short secret cannot partially mask a longer one.
fn trace_secret_env_values() []string {
	mut values := []string{}
	for name, value in os.environ() {
		if value.len < 8 {
			continue
		}
		upper := name.to_upper()
		if upper.contains('KEY') || upper.contains('TOKEN') || upper.contains('SECRET')
			|| upper.contains('PASSWORD') || upper.contains('PASSWD')
			|| upper.contains('CREDENTIAL') || upper.contains('PRIVATE') {
			values << value
		}
	}
	values.sort(a.len > b.len)
	return values
}

fn is_trace_token_byte(b u8) bool {
	return (b >= `a` && b <= `z`) || (b >= `A` && b <= `Z`) || (b >= `0` && b <= `9`)
		|| b in [`_`, `-`, `.`, `=`, `+`, `/`]
}

// Assigned credential values run until a structural delimiter so passwords
// containing punctuation are still fully consumed.
fn is_trace_value_byte(b u8) bool {
	return b !in [` `, `\t`, `\n`, `\r`, `"`, `'`, `\``, `,`, `;`, `}`, `]`, `)`]
}

fn ascii_lower_bytes(text string) []u8 {
	mut bytes := text.bytes()
	for i, b in bytes {
		if b >= `A` && b <= `Z` {
			bytes[i] = b + 32
		}
	}
	return bytes
}

fn bytes_start_with(bytes []u8, at int, prefix string) bool {
	if at + prefix.len > bytes.len {
		return false
	}
	for i, p in prefix.bytes() {
		if bytes[at + i] != p {
			return false
		}
	}
	return true
}

// redact_trace_text removes credentials from one trace string: exact values of
// sensitive environment variables, recognized credential token shapes, and
// values assigned to credential field names. Non-credential content (source
// code, paths, ordinary prose) is preserved.
fn redact_trace_text(text string, secrets []string) string {
	mut redacted := text
	for secret in secrets {
		if secret.len > 0 && redacted.contains(secret) {
			redacted = redacted.replace(secret, trace_redaction_marker)
		}
	}
	return redact_assigned_secrets(redact_prefixed_tokens(redacted))
}

fn redact_prefixed_tokens(text string) string {
	bytes := text.bytes()
	mut out := []u8{cap: bytes.len}
	mut i := 0
	for i < bytes.len {
		mut consumed := 0
		for prefix in trace_secret_prefixes {
			if bytes_start_with(bytes, i, prefix) {
				mut end := i
				for end < bytes.len && is_trace_token_byte(bytes[end]) {
					end++
				}
				// Require a plausible credential tail so ordinary words that
				// merely start with a prefix stay untouched.
				if end - i >= prefix.len + 6 {
					consumed = end - i
				}
				break
			}
		}
		if consumed > 0 {
			out << trace_redaction_marker.bytes()
			i += consumed
		} else {
			out << bytes[i]
			i++
		}
	}
	return out.bytestr()
}

fn redact_assigned_secrets(text string) string {
	bytes := text.bytes()
	lower := ascii_lower_bytes(text)
	mut out := []u8{cap: bytes.len}
	mut i := 0
	for i < bytes.len {
		mut field_len := 0
		if i == 0 || !is_trace_token_byte(bytes[i - 1]) {
			for field in trace_secret_field_names {
				if bytes_start_with(lower, i, field) {
					field_len = field.len
					break
				}
			}
		}
		if field_len == 0 {
			out << bytes[i]
			i++
			continue
		}
		mut cursor := i + field_len
		for cursor < bytes.len && bytes[cursor] in [` `, `\t`] {
			cursor++
		}
		if cursor >= bytes.len || bytes[cursor] !in [`:`, `=`] {
			out << bytes[i]
			i++
			continue
		}
		cursor++
		for cursor < bytes.len && bytes[cursor] in [` `, `\t`] {
			cursor++
		}
		if cursor < bytes.len && bytes[cursor] in [`"`, `'`, `\``] {
			cursor++
		}
		mut value_end := cursor
		for value_end < bytes.len && is_trace_value_byte(bytes[value_end]) {
			value_end++
		}
		if value_end == cursor {
			out << bytes[i]
			i++
			continue
		}
		value := lower[cursor..value_end].bytestr()
		if value in ['bearer', 'basic'] {
			mut token_start := value_end
			for token_start < bytes.len && bytes[token_start] in [` `, `\t`] {
				token_start++
			}
			mut token_end := token_start
			for token_end < bytes.len && is_trace_token_byte(bytes[token_end]) {
				token_end++
			}
			if token_end > token_start {
				value_end = token_end
			}
		}
		out << bytes[i..cursor]
		out << trace_redaction_marker.bytes()
		i = value_end
	}
	return out.bytestr()
}
