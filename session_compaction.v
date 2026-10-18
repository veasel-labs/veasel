module main

import os

// Soft pressure uses UTF-8 payload bytes already counted by agent_context_bytes.
// It is not a provider token window and must not be advertised as one.
const compaction_pressure_ratio_numerator = 3
const compaction_pressure_ratio_denominator = 4
const compaction_keep_recent_bytes = 131_072
const compaction_keep_recent_messages = 16
const compaction_excerpt_chars = 400
const compaction_max_older_excerpts = 48
const compaction_summary_preview_chars = 512
const compaction_native_goal_chars = 160
const compaction_native_max_goals = 8
const compaction_native_max_tools = 16
const compaction_native_max_paths = 24
const compaction_summary_open = '<veasel-context-summary untrusted="true">'
const compaction_summary_close = '</veasel-context-summary>'
const compaction_summarizer_env = 'VEASEL_SESSION_COMPACTION_SUMMARIZER'

// SessionCompactionMeasurement records measured sizes for one compaction.
// estimated_token_bound_* is a conservative bytes/4 bound, never invented usage.
// Provider token fields are copied only when a summarizer adapter reported them.
pub struct SessionCompactionMeasurement {
pub:
	bytes_before                 int
	bytes_after                  int
	estimated_token_bound_before int
	estimated_token_bound_after  int
	summarized_message_count     int
	kept_message_count           int
	triggered                    bool
	reason                       string
	summarizer_mode              string
	usage_reported               bool
	input_tokens                 i64
	output_tokens                i64
}

pub struct SessionCompactionResult {
pub:
	messages    []ChatMessage
	summary     string
	measurement SessionCompactionMeasurement
}

// SessionCompactionSummarizerOutput is a candidate summary body from an optional
// native or LLM summarizer. The body must already include the untrusted wrapper.
pub struct SessionCompactionSummarizerOutput {
pub:
	body  string
	mode  string
	usage ProviderUsage
}

type SessionCompactionSummarizerFn = fn (older []ChatMessage, bytes_before int, reason string) !SessionCompactionSummarizerOutput

fn compaction_pressure_bytes() int {
	return chat_input_byte_limit() * compaction_pressure_ratio_numerator / compaction_pressure_ratio_denominator
}

const compaction_min_keep_bytes = 4_096
const compaction_min_token_input_budget = 1_024

// compaction_reserved_output_tokens resolves the output reserve held back from
// a known context window. A non-positive configured value falls back to the
// default provider output cap so a reserve always exists.
fn compaction_reserved_output_tokens(reserved_output_tokens int) int {
	if reserved_output_tokens > 0 {
		return reserved_output_tokens
	}
	return max_model_output_tokens
}

// compaction_token_input_budget returns the input-token budget for a known
// curated window after reserving room for the reply, or 0 when the window is
// unknown. Unknown models stay unknown: no budget is invented for them.
fn compaction_token_input_budget(model_context_tokens int, reserved_output_tokens int) int {
	if model_context_tokens <= 0 {
		return 0
	}
	usable := model_context_tokens - compaction_reserved_output_tokens(reserved_output_tokens)
	if usable < compaction_min_token_input_budget {
		return compaction_min_token_input_budget
	}
	return usable
}

// compaction_keep_bytes_for_window scales the verbatim recent-history window
// to a known token budget: roughly a quarter of the input budget (tokens are
// bounded at 4 bytes each), clamped so small windows cannot keep a recent
// tail that alone overflows the model window.
fn compaction_keep_bytes_for_window(model_context_tokens int, reserved_output_tokens int) int {
	budget := compaction_token_input_budget(model_context_tokens, reserved_output_tokens)
	if budget <= 0 {
		return compaction_keep_recent_bytes
	}
	keep := budget / 4 * 4
	if keep < compaction_min_keep_bytes {
		return compaction_min_keep_bytes
	}
	if keep > compaction_keep_recent_bytes {
		return compaction_keep_recent_bytes
	}
	return keep
}

fn estimate_token_bound_from_bytes(bytes int) int {
	if bytes <= 0 {
		return 0
	}
	return (bytes + 3) / 4
}

fn message_context_bytes(message ChatMessage) int {
	mut total := message.content.len
	total += message.name.len + message.tool_call_id.len + message.provider_tool_call_id.len
	for context_item in message.provider_context {
		total += context_item.len
	}
	for call in message.tool_calls {
		total += call.function.arguments.len
		total += call.id.len + call.provider_call_id.len + call.provider_signature.len
		total += call.function.name.len
	}
	return total
}

fn session_compaction_due(messages []ChatMessage, model_context_tokens int, reserved_output_tokens int) (bool, string) {
	bytes := agent_context_bytes(messages)
	if bytes >= compaction_pressure_bytes() {
		return true, 'byte_pressure'
	}
	// Token pressure only applies with a curated context window, measured
	// against the input budget left after reserving room for the reply. The
	// bound is the conservative bytes/4 estimate already used for
	// measurements; it is never provider-reported usage.
	token_budget := compaction_token_input_budget(model_context_tokens, reserved_output_tokens)
	if token_budget > 0
		&& estimate_token_bound_from_bytes(bytes) >= token_budget * compaction_pressure_ratio_numerator / compaction_pressure_ratio_denominator {
		return true, 'token_pressure'
	}
	mut conversation := 0
	for message in messages {
		if message.role != 'system' {
			conversation++
		}
	}
	// Leave headroom for an assistant reply and a small tool cycle.
	if conversation >= max_chat_messages - 4 {
		return true, 'message_pressure'
	}
	return false, ''
}

fn first_conversation_index(messages []ChatMessage) int {
	for index, message in messages {
		if message.role != 'system' {
			return index
		}
	}
	return messages.len
}

// find_compaction_cut returns the index where verbatim recent history starts.
// Older messages are summarized. Cuts snap to a user message when possible so
// assistant tool calls stay with their tool results.
fn find_compaction_cut(messages []ChatMessage, keep_bytes int, reason string) int {
	first := first_conversation_index(messages)
	if first >= messages.len {
		return messages.len
	}
	mut total := 0
	mut start := messages.len
	for start > first {
		candidate := start - 1
		size := message_context_bytes(messages[candidate])
		if total + size > keep_bytes && start < messages.len {
			break
		}
		total += size
		start = candidate
	}
	// Message-count pressure can fire while the recent byte budget still holds
	// the whole transcript; force a recent window so older turns are summarized.
	if reason == 'message_pressure' {
		message_cut := messages.len - compaction_keep_recent_messages
		if message_cut > first && message_cut > start {
			start = message_cut
		} else if start <= first && messages.len - first > 1 {
			start = messages.len - 1
		}
	}
	mut cut := start
	for cut > first && messages[cut].role != 'user' {
		cut--
	}
	if cut > first && messages[cut].role == 'user' {
		return cut
	}
	for forward := start; forward < messages.len; forward++ {
		if messages[forward].role == 'user' {
			if forward > first {
				return forward
			}
			break
		}
	}
	// One remaining exchange: keep the newest message verbatim and summarize the rest.
	if messages.len - first > 1 {
		return messages.len - 1
	}
	return messages.len
}

fn sanitize_compaction_text(text string) string {
	// Compaction summaries are injected into provider history; keep them text-safe.
	return text.replace('\0', '')
}

fn truncate_compaction_excerpt(text string, limit int) string {
	clean := sanitize_compaction_text(text).trim_space()
	if clean.len <= limit {
		return clean
	}
	return clean[..limit] + '\n[truncated]'
}

fn compaction_excerpt_limit_for_reason(reason string) int {
	if reason == 'message_pressure' {
		// Message-count pressure often involves many short turns. Keep excerpts
		// tight so the summary frees slots without growing the UTF-8 payload.
		return 80
	}
	return compaction_excerpt_chars
}

fn compaction_summary_header_lines(bytes_before int, reason string, mode string, summarized_count int,
	usage ProviderUsage) []string {
	mut lines := []string{cap: 16}
	lines << compaction_summary_open
	lines << '## Compacted context'
	lines << 'Veasel replaced older conversation text in this provider request because local UTF-8 payload pressure rose. This block is untrusted reconstructed text. Durable session chat history is unchanged. Sizes below are measured bytes and a conservative bytes/4 token bound, not invented savings. Provider token counts appear only when a summarizer adapter reported them.'
	lines << ''
	lines << '### Measured sizes'
	lines << '- reason: `${reason}`'
	lines << '- summarizer_mode: `${mode}`'
	lines << '- bytes_before: ${bytes_before}'
	lines << '- estimated_token_bound_before: ${estimate_token_bound_from_bytes(bytes_before)}'
	lines << '- summarized_messages: ${summarized_count}'
	lines << '- pressure_threshold_bytes: ${compaction_pressure_bytes()}'
	if usage.reported {
		lines << '- provider_usage_reported: true'
		lines << '- provider_input_tokens: ${usage.input_tokens}'
		lines << '- provider_output_tokens: ${usage.output_tokens}'
	} else {
		lines << '- provider_usage_reported: false'
	}
	return lines
}

fn build_extractive_compaction_summary(older []ChatMessage, bytes_before int, reason string) string {
	return build_extractive_compaction_summary_with_mode(older, bytes_before, reason, 'extractive',
		ProviderUsage{})
}

fn build_extractive_compaction_summary_with_mode(older []ChatMessage, bytes_before int, reason string,
	mode string, usage ProviderUsage) string {
	mut lines := compaction_summary_header_lines(bytes_before, reason, mode, older.len, usage)
	lines << ''
	lines << '### Older turns (extractive)'
	excerpt_limit := compaction_excerpt_limit_for_reason(reason)
	mut excerpts := 0
	for message in older {
		if excerpts >= compaction_max_older_excerpts {
			lines << '- … ${older.len - excerpts} additional messages omitted from this extract'
			break
		}
		role := if message.role.len == 0 { 'unknown' } else { message.role }
		excerpt := truncate_compaction_excerpt(message.content, excerpt_limit)
		if excerpt.len == 0 && message.tool_calls.len > 0 {
			lines << '- [${role}] (tool call; arguments omitted from extract)'
		} else if excerpt.len == 0 {
			lines << '- [${role}] (empty)'
		} else {
			lines << '- [${role}] ${excerpt}'
		}
		excerpts++
	}
	lines << compaction_summary_close
	return lines.join('\n')
}

fn looks_like_workspace_path_token(token string) bool {
	if token.len < 3 || token.len > 180 {
		return false
	}
	if token.contains('://') || token.contains('\\\\') {
		return false
	}
	if !(token.contains('/') || token.contains('.')) {
		return false
	}
	for ch in token {
		if (ch >= `a` && ch <= `z`) || (ch >= `A` && ch <= `Z`) || (ch >= `0` && ch <= `9`)
			|| ch == `_` || ch == `-` || ch == `/` || ch == `.` || ch == `+` {
			continue
		}
		return false
	}
	return true
}

fn collect_native_compaction_paths(text string, mut paths []string) {
	for raw in text.split_any(' \t\n\r,;:()[]{}"\'`') {
		token := raw.trim_space().trim_right('.,')
		if !looks_like_workspace_path_token(token) {
			continue
		}
		if paths.any(it == token) {
			continue
		}
		paths << token
		if paths.len >= compaction_native_max_paths {
			return
		}
	}
}

// build_native_compaction_summary produces a structured, denser local summary
// without calling a model. It remains untrusted reconstructed text.
fn build_native_compaction_summary(older []ChatMessage, bytes_before int, reason string) string {
	mut lines := compaction_summary_header_lines(bytes_before, reason, 'native', older.len,
		ProviderUsage{})
	mut goals := []string{cap: compaction_native_max_goals}
	mut tools := []string{cap: compaction_native_max_tools}
	mut paths := []string{cap: compaction_native_max_paths}
	for message in older {
		collect_native_compaction_paths(message.content, mut paths)
		if message.role == 'user' && goals.len < compaction_native_max_goals {
			excerpt := truncate_compaction_excerpt(message.content, compaction_native_goal_chars)
			if excerpt.len > 0 {
				goals << excerpt
			}
		}
		for call in message.tool_calls {
			name := call.function.name.trim_space()
			if name.len == 0 || tools.any(it == name) {
				continue
			}
			tools << name
			if tools.len >= compaction_native_max_tools {
				break
			}
		}
	}
	lines << ''
	lines << '### Recent user goals (native extract)'
	if goals.len == 0 {
		lines << '- (none captured)'
	} else {
		start := if goals.len > compaction_native_max_goals {
			goals.len - compaction_native_max_goals
		} else {
			0
		}
		for goal in goals[start..] {
			lines << '- ${goal}'
		}
	}
	lines << ''
	lines << '### Tools observed'
	if tools.len == 0 {
		lines << '- (none)'
	} else {
		for name in tools {
			lines << '- ${name}'
		}
	}
	lines << ''
	lines << '### Path-like tokens'
	if paths.len == 0 {
		lines << '- (none)'
	} else {
		for path in paths {
			lines << '- ${path}'
		}
	}
	lines << compaction_summary_close
	return lines.join('\n')
}

fn wrap_llm_compaction_summary(model_text string, bytes_before int, reason string, usage ProviderUsage,
	summarized_count int) string {
	mut lines := compaction_summary_header_lines(bytes_before, reason, 'llm', summarized_count, usage)
	lines << ''
	lines << '### LLM summary (untrusted)'
	lines << truncate_compaction_excerpt(model_text, 4_000)
	lines << compaction_summary_close
	return lines.join('\n')
}

fn native_session_compaction_summarizer(older []ChatMessage, bytes_before int, reason string) !SessionCompactionSummarizerOutput {
	return SessionCompactionSummarizerOutput{
		body: build_native_compaction_summary(older, bytes_before, reason)
		mode: 'native'
	}
}

fn session_compaction_summarizer_mode() string {
	raw := os.getenv_opt(compaction_summarizer_env) or { 'extractive' }
	value := raw.trim_space().to_lower()
	return match value {
		'native', 'llm' { value }
		else { 'extractive' }
	}
}

fn session_compaction_summarizer_enabled() bool {
	mode := session_compaction_summarizer_mode()
	return mode == 'native' || mode == 'llm'
}

fn compaction_accepts_candidate(reason string, bytes_before int, messages_before int, candidate []ChatMessage) bool {
	bytes_after := agent_context_bytes(candidate)
	reduced_bytes := bytes_after < bytes_before
	reduced_messages := candidate.len < messages_before
	if reason == 'message_pressure' {
		return reduced_messages || reduced_bytes
	}
	return reduced_bytes
}

fn assemble_compacted_messages(messages []ChatMessage, first int, cut int, summary string) []ChatMessage {
	mut compacted := []ChatMessage{cap: first + 2 + (messages.len - cut)}
	for index in 0 .. first {
		compacted << messages[index]
	}
	compacted << ChatMessage{
		role:    'user'
		content: summary
	}
	for index in cut .. messages.len {
		compacted << messages[index]
	}
	return compacted
}

fn compaction_result_unchanged(messages []ChatMessage, bytes_before int, reason string) SessionCompactionResult {
	bound_before := estimate_token_bound_from_bytes(bytes_before)
	return SessionCompactionResult{
		messages:    messages
		measurement: SessionCompactionMeasurement{
			bytes_before:                 bytes_before
			bytes_after:                  bytes_before
			estimated_token_bound_before: bound_before
			estimated_token_bound_after:  bound_before
			kept_message_count:           messages.len
			reason:                       reason
			summarizer_mode:              'extractive'
		}
	}
}

fn finalize_compaction_result(compacted []ChatMessage, summary string, bytes_before int, reason string,
	summarized_count int, summarizer_mode string, usage ProviderUsage) SessionCompactionResult {
	bytes_after := agent_context_bytes(compacted)
	return SessionCompactionResult{
		messages:    compacted
		summary:     summary
		measurement: SessionCompactionMeasurement{
			bytes_before:                 bytes_before
			bytes_after:                  bytes_after
			estimated_token_bound_before: estimate_token_bound_from_bytes(bytes_before)
			estimated_token_bound_after:  estimate_token_bound_from_bytes(bytes_after)
			summarized_message_count:     summarized_count
			kept_message_count:           compacted.len
			triggered:                    true
			reason:                       reason
			summarizer_mode:              summarizer_mode
			usage_reported:               usage.reported
			input_tokens:                 usage.input_tokens
			output_tokens:                usage.output_tokens
		}
	}
}

// compact_session_messages replaces older conversation with one untrusted
// extractive summary when pressure is due. System messages stay verbatim.
fn compact_session_messages(messages []ChatMessage, model_context_tokens int, reserved_output_tokens int) SessionCompactionResult {
	bytes_before := agent_context_bytes(messages)
	due, reason := session_compaction_due(messages, model_context_tokens, reserved_output_tokens)
	if !due {
		return compaction_result_unchanged(messages, bytes_before, '')
	}
	return apply_extractive_compaction(messages, bytes_before, reason, 'extractive', ProviderUsage{},
		compaction_keep_bytes_for_window(model_context_tokens, reserved_output_tokens))
}

// compact_session_messages_with_summarizer tries a native/LLM summarizer first.
// On summarizer error, empty body, or a candidate that grows measured context,
// it falls back to the extractive summary. Durable history is never modified.
fn compact_session_messages_with_summarizer(messages []ChatMessage, intended_mode string,
	summarizer SessionCompactionSummarizerFn, model_context_tokens int, reserved_output_tokens int) SessionCompactionResult {
	bytes_before := agent_context_bytes(messages)
	due, reason := session_compaction_due(messages, model_context_tokens, reserved_output_tokens)
	if !due {
		return compaction_result_unchanged(messages, bytes_before, '')
	}
	first := first_conversation_index(messages)
	cut := find_compaction_cut(messages, compaction_keep_bytes_for_window(model_context_tokens,
		reserved_output_tokens), reason)
	if cut <= first || cut >= messages.len {
		return compaction_result_unchanged(messages, bytes_before, reason)
	}
	older := messages[first..cut]
	if older.len == 0 {
		return compaction_result_unchanged(messages, bytes_before, reason)
	}
	fallback_mode := compaction_fallback_mode(intended_mode)
	attempt := summarizer(older, bytes_before, reason) or {
		return apply_extractive_compaction(messages, bytes_before, reason, fallback_mode, ProviderUsage{},
			compaction_keep_bytes_for_window(model_context_tokens, reserved_output_tokens))
	}
	return compact_session_messages_preferring(messages, intended_mode, attempt, model_context_tokens,
		reserved_output_tokens)
}

// compact_session_messages_preferring applies a precomputed summarizer output or
// falls back to extractive when the candidate is empty or grows measured context.
fn compact_session_messages_preferring(messages []ChatMessage, intended_mode string,
	attempt SessionCompactionSummarizerOutput, model_context_tokens int, reserved_output_tokens int) SessionCompactionResult {
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
	fallback_mode := compaction_fallback_mode(intended_mode)
	summary_body := sanitize_compaction_text(attempt.body)
	if summary_body.trim_space().len == 0 {
		return apply_extractive_compaction(messages, bytes_before, reason, fallback_mode, attempt.usage,
			keep_bytes)
	}
	candidate := assemble_compacted_messages(messages, first, cut, summary_body)
	if compaction_accepts_candidate(reason, bytes_before, messages.len, candidate) {
		mode := if attempt.mode.len > 0 { attempt.mode } else { intended_mode }
		return finalize_compaction_result(candidate, summary_body, bytes_before, reason, older.len,
			mode, attempt.usage)
	}
	return apply_extractive_compaction(messages, bytes_before, reason, fallback_mode, attempt.usage,
		keep_bytes)
}

fn compaction_fallback_mode(intended_mode string) string {
	if intended_mode == 'native' || intended_mode == 'llm' {
		return '${intended_mode}_fallback_extractive'
	}
	return 'llm_fallback_extractive'
}

fn apply_extractive_compaction(messages []ChatMessage, bytes_before int, reason string, mode string,
	usage ProviderUsage, keep_bytes int) SessionCompactionResult {
	first := first_conversation_index(messages)
	cut := find_compaction_cut(messages, keep_bytes, reason)
	if cut <= first || cut >= messages.len {
		return compaction_result_unchanged(messages, bytes_before, reason)
	}
	older := messages[first..cut]
	if older.len == 0 {
		return compaction_result_unchanged(messages, bytes_before, reason)
	}
	summary := build_extractive_compaction_summary_with_mode(older, bytes_before, reason, mode, usage)
	compacted := assemble_compacted_messages(messages, first, cut, summary)
	if !compaction_accepts_candidate(reason, bytes_before, messages.len, compacted) {
		return compaction_result_unchanged(messages, bytes_before, reason)
	}
	return finalize_compaction_result(compacted, summary, bytes_before, reason, older.len, mode, usage)
}

fn compaction_summary_preview(summary string) string {
	if summary.len <= compaction_summary_preview_chars {
		return summary
	}
	return summary[..compaction_summary_preview_chars] + '\n[truncated]'
}
