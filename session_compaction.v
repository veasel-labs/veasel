module main

// Soft pressure uses UTF-8 payload bytes already counted by agent_context_bytes.
// It is not a provider token window and must not be advertised as one.
const compaction_pressure_ratio_numerator = 3
const compaction_pressure_ratio_denominator = 4
const compaction_keep_recent_bytes = 131_072
const compaction_keep_recent_messages = 16
const compaction_excerpt_chars = 400
const compaction_max_older_excerpts = 48
const compaction_summary_preview_chars = 512
const compaction_summary_open = '<veasel-context-summary untrusted="true">'
const compaction_summary_close = '</veasel-context-summary>'

// SessionCompactionMeasurement records measured sizes for one compaction.
// estimated_token_bound_* is a conservative bytes/4 bound, never provider usage.
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
}

pub struct SessionCompactionResult {
pub:
	messages    []ChatMessage
	summary     string
	measurement SessionCompactionMeasurement
}

fn compaction_pressure_bytes() int {
	return max_chat_input_bytes * compaction_pressure_ratio_numerator / compaction_pressure_ratio_denominator
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

fn session_compaction_due(messages []ChatMessage) (bool, string) {
	bytes := agent_context_bytes(messages)
	if bytes >= compaction_pressure_bytes() {
		return true, 'byte_pressure'
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

fn truncate_compaction_excerpt(text string, limit int) string {
	clean := text.trim_space()
	if clean.len <= limit {
		return clean
	}
	return clean[..limit] + '\n[truncated]'
}

fn build_extractive_compaction_summary(older []ChatMessage, bytes_before int, reason string) string {
	mut lines := []string{cap: 16 + older.len}
	lines << compaction_summary_open
	lines << '## Compacted context'
	lines << 'Veasel replaced older conversation text in this provider request because local UTF-8 payload pressure rose. This block is untrusted reconstructed text. Durable session chat history is unchanged. Sizes below are measured bytes and a conservative bytes/4 token bound, not provider-reported usage.'
	lines << ''
	lines << '### Measured sizes'
	lines << '- reason: `${reason}`'
	lines << '- bytes_before: ${bytes_before}'
	lines << '- estimated_token_bound_before: ${estimate_token_bound_from_bytes(bytes_before)}'
	lines << '- summarized_messages: ${older.len}'
	lines << '- pressure_threshold_bytes: ${compaction_pressure_bytes()}'
	lines << ''
	lines << '### Older turns (extractive)'
	mut excerpts := 0
	for message in older {
		if excerpts >= compaction_max_older_excerpts {
			lines << '- … ${older.len - excerpts} additional messages omitted from this extract'
			break
		}
		role := if message.role.len == 0 { 'unknown' } else { message.role }
		excerpt := truncate_compaction_excerpt(message.content, compaction_excerpt_chars)
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

// compact_session_messages replaces older conversation with one untrusted
// extractive summary when pressure is due. System messages stay verbatim.
fn compact_session_messages(messages []ChatMessage) SessionCompactionResult {
	bytes_before := agent_context_bytes(messages)
	due, reason := session_compaction_due(messages)
	bound_before := estimate_token_bound_from_bytes(bytes_before)
	if !due {
		return SessionCompactionResult{
			messages:    messages
			measurement: SessionCompactionMeasurement{
				bytes_before:                 bytes_before
				bytes_after:                  bytes_before
				estimated_token_bound_before: bound_before
				estimated_token_bound_after:  bound_before
				kept_message_count:           messages.len
			}
		}
	}
	first := first_conversation_index(messages)
	cut := find_compaction_cut(messages, compaction_keep_recent_bytes, reason)
	if cut <= first || cut >= messages.len {
		return SessionCompactionResult{
			messages:    messages
			measurement: SessionCompactionMeasurement{
				bytes_before:                 bytes_before
				bytes_after:                  bytes_before
				estimated_token_bound_before: bound_before
				estimated_token_bound_after:  bound_before
				kept_message_count:           messages.len
				reason:                       reason
			}
		}
	}
	older := messages[first..cut]
	if older.len == 0 {
		return SessionCompactionResult{
			messages:    messages
			measurement: SessionCompactionMeasurement{
				bytes_before:                 bytes_before
				bytes_after:                  bytes_before
				estimated_token_bound_before: bound_before
				estimated_token_bound_after:  bound_before
				kept_message_count:           messages.len
				reason:                       reason
			}
		}
	}
	summary := build_extractive_compaction_summary(older, bytes_before, reason)
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
	bytes_after := agent_context_bytes(compacted)
	// Refuse a compaction that does not reduce measured payload bytes.
	if bytes_after >= bytes_before {
		return SessionCompactionResult{
			messages:    messages
			measurement: SessionCompactionMeasurement{
				bytes_before:                 bytes_before
				bytes_after:                  bytes_before
				estimated_token_bound_before: bound_before
				estimated_token_bound_after:  bound_before
				kept_message_count:           messages.len
				reason:                       reason
			}
		}
	}
	return SessionCompactionResult{
		messages:    compacted
		summary:     summary
		measurement: SessionCompactionMeasurement{
			bytes_before:                 bytes_before
			bytes_after:                  bytes_after
			estimated_token_bound_before: bound_before
			estimated_token_bound_after:  estimate_token_bound_from_bytes(bytes_after)
			summarized_message_count:     older.len
			kept_message_count:           compacted.len
			triggered:                    true
			reason:                       reason
		}
	}
}

fn compaction_summary_preview(summary string) string {
	if summary.len <= compaction_summary_preview_chars {
		return summary
	}
	return summary[..compaction_summary_preview_chars] + '\n[truncated]'
}
