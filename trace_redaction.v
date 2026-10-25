module main

import json2
import os

const trace_redaction_marker = '[REDACTED]'

// Credential-shaped token prefixes recognized even when the exact value never
// appeared in this process's environment (for example keys pasted into a task,
// printed by a tool, or returned by an MCP server).
const trace_secret_prefixes = ['sk-', 'sk_', 'ghp_', 'gho_', 'ghu_', 'ghs_', 'ghr_', 'github_pat_',
	'xoxb-', 'xoxp-', 'xoxa-', 'xoxs-', 'xoxr-', 'AIza', 'AKIA', 'LLM_', 'eyJ']
const trace_secret_prefix_initial_bytes = 'sgxALe'

// Field names whose values are credentials wherever they appear, in trace text
// assignments (`token = ...`) and in structured tool-call arguments alike.
const trace_secret_field_names = ['api_key', 'api-key', 'api key', 'apikey', 'access_token',
	'access-token', 'access token', 'auth_token', 'auth-token', 'client_secret', 'client-secret',
	'client secret', 'password', 'passwd', 'secret', 'token', 'authorization']
const trace_secret_field_initial_bytes = 'aAcCpPsStT'

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

fn trace_ascii_lower_byte(value u8) u8 {
	if value >= `A` && value <= `Z` {
		return value + 32
	}
	return value
}

fn trace_text_starts_with(text string, at int, prefix string) bool {
	if at < 0 || at + prefix.len > text.len {
		return false
	}
	for i in 0 .. prefix.len {
		if text[at + i] != prefix[i] {
			return false
		}
	}
	return true
}

fn trace_text_starts_with_ascii_ci(text string, at int, prefix string) bool {
	if at < 0 || at + prefix.len > text.len {
		return false
	}
	for i in 0 .. prefix.len {
		if trace_ascii_lower_byte(text[at + i]) != prefix[i] {
			return false
		}
	}
	return true
}

fn trace_text_region_equals_ascii_ci(text string, start int, end int, expected string) bool {
	return end >= start && end - start == expected.len && trace_text_starts_with_ascii_ci(text,
		start, expected)
}

fn append_trace_text_range(mut out []u8, text string, start int, end int) {
	for index in start .. end {
		out << text[index]
	}
}

// redact_trace_text removes credentials from one trace string: exact values of
// sensitive environment variables, recognized credential token shapes, and
// values assigned to credential field names. Non-credential content (source
// code, paths, ordinary prose) is preserved.
fn redact_trace_text(text string, secrets []string) string {
	// Drop binary-unsafe NULs before credential redaction so ATIF JSON stays text-safe.
	sanitized := strip_trace_nuls(text)
	mut redacted := redact_pem_blocks(sanitized)
	for secret in secrets {
		if secret.len > 0 && redacted.contains(secret) {
			redacted = redacted.replace(secret, trace_redaction_marker)
		}
	}
	safe := redact_assigned_secrets(redact_prefixed_tokens(redacted))
	// V strings are immutable; return the unchanged input without cloning the
	// complete message when no sanitization or redaction changed it.
	return safe
}

fn strip_trace_nuls(text string) string {
	mut first_nul := -1
	for index in 0 .. text.len {
		if text[index] == 0 {
			first_nul = index
			break
		}
	}
	if first_nul < 0 {
		return text
	}
	mut out := []u8{cap: text.len}
	append_trace_text_range(mut out, text, 0, first_nul)
	for index in first_nul .. text.len {
		if text[index] != 0 {
			out << text[index]
		}
	}
	return out.bytestr()
}

// redact_pem_blocks replaces a complete BEGIN/END block. An opening marker
// without a matching END is left in place so a mention of the marker cannot
// erase the rest of the trace.
fn redact_pem_blocks(text string) string {
	mut out := []u8{}
	mut unchanged_start := 0
	mut changed := false
	mut i := 0
	for i < text.len {
		if text[i] != `-` {
			i++
			continue
		}
		if trace_text_starts_with(text, i, '-----BEGIN') {
			end_at := index_trace_text_from(text, '-----END', i + 10)
			close := if end_at >= 0 { index_trace_text_from(text, '-----', end_at + 8) } else { -1 }
			if close >= 0 {
				if !changed {
					out = []u8{cap: text.len}
				}
				append_trace_text_range(mut out, text, unchanged_start, i)
				append_trace_text_range(mut out, trace_redaction_marker, 0, trace_redaction_marker.len)
				changed = true
				i = close + 5
				unchanged_start = i
				continue
			}
		}
		i++
	}
	if !changed {
		return text
	}
	append_trace_text_range(mut out, text, unchanged_start, text.len)
	return out.bytestr()
}

fn index_trace_text_from(text string, needle string, start int) int {
	if start < 0 {
		return -1
	}
	for i in start .. text.len {
		if trace_text_starts_with(text, i, needle) {
			return i
		}
	}
	return -1
}

fn redact_prefixed_tokens(text string) string {
	mut out := []u8{}
	mut unchanged_start := 0
	mut changed := false
	mut i := 0
	for i < text.len {
		// All recognized token prefixes start with one of these bytes. Most
		// trace text can skip the prefix table with a single byte comparison.
		if !trace_secret_prefix_initial_bytes.contains_u8(text[i]) {
			i++
			continue
		}
		mut consumed := 0
		for prefix in trace_secret_prefixes {
			if trace_text_starts_with(text, i, prefix) {
				mut end := i
				for end < text.len && is_trace_token_byte(text[end]) {
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
			if !changed {
				out = []u8{cap: text.len}
			}
			append_trace_text_range(mut out, text, unchanged_start, i)
			append_trace_text_range(mut out, trace_redaction_marker, 0, trace_redaction_marker.len)
			changed = true
			i += consumed
			unchanged_start = i
		} else {
			i++
		}
	}
	if !changed {
		return text
	}
	append_trace_text_range(mut out, text, unchanged_start, text.len)
	return out.bytestr()
}

fn redact_assigned_secrets(text string) string {
	mut out := []u8{}
	mut unchanged_start := 0
	mut changed := false
	mut i := 0
	for i < text.len {
		// Secret field names are ASCII case-insensitive and start with only
		// these letters, so ordinary prose avoids the field-name scan.
		if !trace_secret_field_initial_bytes.contains_u8(text[i]) {
			i++
			continue
		}
		mut field_len := 0
		if i == 0 || !is_trace_token_byte(text[i - 1]) {
			for field in trace_secret_field_names {
				if trace_text_starts_with_ascii_ci(text, i, field) {
					field_len = field.len
					break
				}
			}
		}
		if field_len == 0 {
			i++
			continue
		}
		mut cursor := i + field_len
		for cursor < text.len && text[cursor] in [` `, `\t`] {
			cursor++
		}
		if cursor >= text.len || text[cursor] !in [`:`, `=`] {
			i++
			continue
		}
		cursor++
		for cursor < text.len && text[cursor] in [` `, `\t`] {
			cursor++
		}
		if cursor < text.len && text[cursor] in [`"`, `'`, `\``] {
			cursor++
		}
		mut value_end := cursor
		for value_end < text.len && is_trace_value_byte(text[value_end]) {
			value_end++
		}
		if value_end == cursor {
			i++
			continue
		}
		if trace_text_region_equals_ascii_ci(text, cursor, value_end, 'bearer')
			|| trace_text_region_equals_ascii_ci(text, cursor, value_end, 'basic') {
			mut token_start := value_end
			for token_start < text.len && text[token_start] in [` `, `\t`] {
				token_start++
			}
			mut token_end := token_start
			for token_end < text.len && is_trace_token_byte(text[token_end]) {
				token_end++
			}
			if token_end > token_start {
				value_end = token_end
			}
		}
		if !changed {
			out = []u8{cap: text.len}
		}
		append_trace_text_range(mut out, text, unchanged_start, cursor)
		append_trace_text_range(mut out, trace_redaction_marker, 0, trace_redaction_marker.len)
		changed = true
		i = value_end
		unchanged_start = i
	}
	if !changed {
		return text
	}
	append_trace_text_range(mut out, text, unchanged_start, text.len)
	return out.bytestr()
}
