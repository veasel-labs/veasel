module main

import json2
import uuid

// Context handoffs live in the existing per-session event stream. Keep the
// nested artifact deliberately small so it remains safe inside EventData.delta.
const max_context_handoff_event_bytes = 256 * 1024
const max_context_handoff_transcript_bytes = 32 * 1024
const max_context_handoff_messages = 64
const context_handoff_event_type = 'session.context_handoff'

pub struct ContextHandoffMessage {
pub:
	message_id int
	role       string
	content    string
	truncated  bool
}

// ContextHandoffArtifact is application-owned. Provider-specific request IDs
// and hidden reasoning are intentionally absent; the workspace remains the
// canonical conversation and this record is only an explicit bounded handoff.
pub struct ContextHandoffArtifact {
pub:
	artifact_id                  string
	session_id                   string
	source_operation_id          string
	next_operation_id            string
	source_provider              string
	source_model                 string
	target_provider              string
	target_model                 string
	context_mode                 string
	base_message_id              int
	first_message_id             int
	through_message_id           int
	transcript                   []ContextHandoffMessage
	transcript_bytes             int
	omitted_message_count        int
	transcript_complete          bool
	fallback_reason              string
	workspace_snapshot_ref       string
	workspace_snapshot_scope     string
	permission_policy_source     string
	permission_policy_mode       string
	permission_interactive       bool
	permissions_inherited        bool
	hidden_reasoning_transferred bool

pub mut:
	created_at string
}

struct ContextHandoffLookup {
	found    bool
	artifact ContextHandoffArtifact
}

// persist_context_handoff records a route change before the next provider call.
// The session ID stays stable; the operation IDs and provider/model pair make
// the transfer attributable without importing provider-native identifiers.
fn (mut store Store) persist_context_handoff(session_id string, next_operation_id string,
	target_provider string, target_model string, policy ExecutionPolicyTurn,
	policy_source string) !ContextHandoffArtifact {
	if !validate_operation_id(next_operation_id) {
		return error('context handoff operation identifier is invalid')
	}
	validate_context_handoff_route(target_provider, target_model)!
	if policy_source !in ['parent_turn', 'manual_user_action', 'recovered_operation'] {
		return error('context handoff permission provenance is invalid')
	}
	prior_lookup := store.find_context_handoff_for_operation(session_id, next_operation_id)!
	if prior_lookup.found {
		prior := prior_lookup.artifact
		if prior.target_provider != target_provider || prior.target_model != target_model
			|| prior.permission_policy_mode != execution_policy_mode_label(policy.mode)
			|| prior.permission_interactive != policy.interactive
			|| prior.permission_policy_source != policy_source {
			return error('context handoff operation was already recorded with different routing or permissions')
		}
		return prior
	}
	session := store.get_session(session_id)!
	operations := store.list_session_operations(session_id)!
	mut source_operation := SessionOperation{}
	for operation in operations {
		if operation.status == 'completed' && operation.provider.len > 0 && operation.model.len > 0 {
			source_operation = operation
		}
	}
	if source_operation.id.len == 0 {
		return error('context handoff requires a completed source provider operation')
	}
	if source_operation.provider == target_provider && source_operation.model == target_model {
		return error('context handoff target matches the current provider and model')
	}
	previous := store.latest_context_handoff(session_id)!
	mut mode := 'full'
	mut base_message_id := 0
	mut fallback_reason := 'no prior handoff checkpoint; using a bounded full-context snapshot'
	mut messages := store.context_handoff_full_messages(session_id)!
	if previous.artifact_id.len > 0 {
		last := previous
		if last.target_provider == source_operation.provider && last.target_model == source_operation.model {
			mode = 'delta'
			base_message_id = last.through_message_id
			fallback_reason = ''
			messages = store.context_handoff_messages_after(session_id, base_message_id,
				max_context_handoff_messages + 1)!
			if messages.len > max_context_handoff_messages
				|| context_handoff_messages_bytes(messages) > max_context_handoff_transcript_bytes {
				mode = 'full'
				fallback_reason = 'transcript delta exceeded the handoff message or byte bound; using a bounded full-context snapshot'
				messages = store.context_handoff_full_messages(session_id)!
			}
		} else {
			fallback_reason = 'previous handoff target does not match the source route; using a bounded full-context snapshot'
		}
	}
	entries, transcript_bytes, omitted_from_window, complete := bounded_context_handoff_messages(messages)
	if entries.len == 0 {
		return error('context handoff transcript is empty')
	}
	mut omitted := omitted_from_window
	if mode == 'full' {
		omitted += store.max_context_handoff_message_count(session_id)! - messages.len
	}
	first_id := entries[0].message_id
	through_id := entries[entries.len - 1].message_id
	workspace_ref, workspace_scope := context_handoff_workspace_reference(session.directory)
	artifact := ContextHandoffArtifact{
		artifact_id:                  uuid.new_v4().str()
		session_id:                   session_id
		source_operation_id:          source_operation.id
		next_operation_id:            next_operation_id
		source_provider:              source_operation.provider
		source_model:                 source_operation.model
		target_provider:              target_provider
		target_model:                 target_model
		context_mode:                 mode
		base_message_id:              base_message_id
		first_message_id:             first_id
		through_message_id:           through_id
		transcript:                   entries
		transcript_bytes:             transcript_bytes
		omitted_message_count:        omitted
		transcript_complete:          complete
		fallback_reason:              fallback_reason
		workspace_snapshot_ref:       workspace_ref
		workspace_snapshot_scope:     workspace_scope
		permission_policy_source:     policy_source
		permission_policy_mode:       execution_policy_mode_label(policy.mode)
		permission_interactive:       policy.interactive
		permissions_inherited:        true
		hidden_reasoning_transferred: false
	}
	encoded := json2.encode(artifact)
	if encoded.len > max_context_handoff_event_bytes {
		return error('context handoff artifact exceeds its storage bound')
	}
	store.record_context_handoff_artifact(artifact, encoded)!
	return store.context_handoff_for_operation(session_id, next_operation_id)!
}

fn validate_context_handoff_route(provider string, model string) ! {
	if provider.trim_space().len == 0 || provider.len > 100 || model.trim_space().len == 0
		|| model.len > 200 || provider.contains('\0') || model.contains('\0')
		|| model_settings_text_has_unsafe_controls(provider)
		|| model_settings_text_has_unsafe_controls(model) {
		return error('context handoff provider and model identifiers are invalid')
	}
}

fn (mut store Store) record_context_handoff_artifact(artifact ContextHandoffArtifact,
	encoded string) ! {
	if encoded.len == 0 || encoded.len > max_context_handoff_event_bytes {
		return error('context handoff artifact exceeds its storage bound')
	}
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	store.db.begin()!
	sessions := store.db.exec_param('SELECT id FROM sessions WHERE id = ?', artifact.session_id) or {
		store.db.rollback() or {}
		return error('session not found')
	}
	if sessions.len != 1 {
		store.db.rollback() or {}
		return error('session not found')
	}
	operation := store.db.exec_param_many('SELECT id FROM session_operations WHERE session_id = ? AND id = ?',
		[artifact.session_id, artifact.next_operation_id]) or {
		store.db.rollback() or {}
		return error('unable to verify context handoff operation')
	}
	if operation.len != 1 {
		store.db.rollback() or {}
		return error('context handoff operation not found')
	}
	existing := store.db.exec_param_many('SELECT data FROM events WHERE session_id = ? AND type = ? ORDER BY id DESC',
		[artifact.session_id, context_handoff_event_type]) or {
		store.db.rollback() or {}
		return error('unable to check context handoff idempotency')
	}
	for row in existing {
		event_data := json2.decode[EventData](row.val(0)) or { continue }
		prior := json2.decode[ContextHandoffArtifact](event_data.delta) or { continue }
		if prior.next_operation_id == artifact.next_operation_id {
			store.db.rollback() or {}
			if prior.source_operation_id != artifact.source_operation_id
				|| prior.target_provider != artifact.target_provider || prior.target_model != artifact.target_model
				|| prior.permission_policy_mode != artifact.permission_policy_mode
				|| prior.permission_interactive != artifact.permission_interactive
				|| prior.permission_policy_source != artifact.permission_policy_source {
				return error('context handoff operation was already recorded with different routing or permissions')
			}
			return
		}
	}
	_ = store.db.exec_param_many('INSERT INTO events (type, session_id, data) VALUES (?, ?, ?)', [
		context_handoff_event_type,
		artifact.session_id,
		json2.encode[EventData](EventData{
			delta: encoded
		}),
	]) or {
		store.db.rollback() or {}
		return error('unable to persist context handoff artifact')
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit context handoff artifact')
	}
	store.prune_session_events_unlocked(artifact.session_id)
}

fn (mut store Store) context_handoff_for_operation(session_id string,
	next_operation_id string) !ContextHandoffArtifact {
	lookup := store.find_context_handoff_for_operation(session_id, next_operation_id)!
	if !lookup.found {
		return error('context handoff artifact not found')
	}
	return lookup.artifact
}

fn (mut store Store) find_context_handoff_for_operation(session_id string,
	next_operation_id string) !ContextHandoffLookup {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	rows := store.db.exec_param_many('SELECT created_at, data FROM events WHERE session_id = ? AND type = ? ORDER BY id DESC',
		[session_id, context_handoff_event_type])!
	for row in rows {
		event_data := json2.decode[EventData](row.val(1)) or { continue }
		artifact := json2.decode[ContextHandoffArtifact](event_data.delta) or { continue }
		if artifact.next_operation_id == next_operation_id {
			mut result := artifact
			result.created_at = row.val(0)
			return ContextHandoffLookup{
				found:    true
				artifact: result
			}
		}
	}
	return ContextHandoffLookup{}
}

fn (mut store Store) list_context_handoffs(session_id string) ![]ContextHandoffArtifact {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	rows := store.db.exec_param_many('SELECT created_at, data FROM events WHERE session_id = ? AND type = ? ORDER BY id ASC',
		[session_id, context_handoff_event_type])!
	mut artifacts := []ContextHandoffArtifact{cap: rows.len}
	for row in rows {
		event_data := json2.decode[EventData](row.val(1)) or {
			return error('stored context handoff event is invalid')
		}
		mut artifact := json2.decode[ContextHandoffArtifact](event_data.delta) or {
			return error('stored context handoff artifact is invalid')
		}
		artifact.created_at = row.val(0)
		artifacts << artifact
	}
	return artifacts
}

fn (mut store Store) latest_context_handoff(session_id string) !ContextHandoffArtifact {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	rows := store.db.exec_param_many('SELECT created_at, data FROM events WHERE session_id = ? AND type = ? ORDER BY id DESC LIMIT 1',
		[session_id, context_handoff_event_type])!
	if rows.len == 0 {
		return ContextHandoffArtifact{}
	}
	event_data := json2.decode[EventData](rows[0].val(1)) or {
		return error('stored context handoff event is invalid')
	}
	mut artifact := json2.decode[ContextHandoffArtifact](event_data.delta) or {
		return error('stored context handoff artifact is invalid')
	}
	artifact.created_at = rows[0].val(0)
	return artifact
}

fn (mut store Store) context_handoff_full_messages(session_id string) ![]ChatTurn {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	rows := store.db.exec_param_many('SELECT id, session_id, role, content, created_at FROM messages WHERE session_id = ? ORDER BY id DESC LIMIT ?',
		[session_id, max_context_handoff_messages.str()])!
	mut messages := []ChatTurn{cap: rows.len}
	for row in rows.reverse() {
		messages << ChatTurn{
			id:         row.val(0).int()
			session_id: row.val(1)
			role:       row.val(2)
			content:    row.val(3)
			created_at: row.val(4)
		}
	}
	return messages
}

fn (mut store Store) max_context_handoff_message_count(session_id string) !int {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	rows := store.db.exec_param('SELECT COUNT(*) FROM messages WHERE session_id = ?', session_id)!
	if rows.len != 1 {
		return error('unable to count handoff messages')
	}
	return rows[0].val(0).int()
}

fn (mut store Store) context_handoff_messages_after(session_id string, message_id int,
	limit int) ![]ChatTurn {
	if message_id < 0 || limit < 1 || limit > max_context_handoff_messages + 1 {
		return error('context handoff message cursor is invalid')
	}
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	rows := store.db.exec_param_many('SELECT id, session_id, role, content, created_at FROM messages WHERE session_id = ? AND id > ? ORDER BY id ASC LIMIT ?',
		[session_id, message_id.str(), limit.str()])!
	mut messages := []ChatTurn{cap: rows.len}
	for row in rows {
		messages << ChatTurn{
			id:         row.val(0).int()
			session_id: row.val(1)
			role:       row.val(2)
			content:    row.val(3)
			created_at: row.val(4)
		}
	}
	return messages
}

fn context_handoff_messages_bytes(messages []ChatTurn) int {
	mut total := 0
	for message in messages {
		total += message.content.len
	}
	return total
}

fn bounded_context_handoff_messages(messages []ChatTurn) ([]ContextHandoffMessage, int, int, bool) {
	mut entries := []ContextHandoffMessage{}
	mut total_bytes := 0
	mut omitted := 0
	mut truncated_any := false
	for index := messages.len - 1; index >= 0; index-- {
		message := messages[index]
		remaining := max_context_handoff_transcript_bytes - total_bytes
		if remaining <= 0 {
			omitted += index + 1
			break
		}
		content := if message.content.len > remaining {
			truncated_any = true
			truncate_context_handoff_utf8(message.content, remaining)
		} else {
			message.content
		}
		if content.len == 0 {
			omitted++
			continue
		}
		total_bytes += content.len
		entries << ContextHandoffMessage{
			message_id: message.id
			role:       message.role
			content:    content
			truncated:  content.len != message.content.len
		}
		if content.len != message.content.len {
			truncated_any = true
			omitted += index
			break
		}
	}
	entries.reverse_in_place()
	return entries, total_bytes, omitted, omitted == 0 && !truncated_any
}

fn truncate_context_handoff_utf8(value string, byte_limit int) string {
	if byte_limit <= 0 {
		return ''
	}
	if value.len <= byte_limit {
		return value.clone()
	}
	mut end := byte_limit
	for end > 0 && (unsafe { value.str[end] } & 0xc0) == 0x80 {
		end--
	}
	return value[..end].clone()
}

fn context_handoff_workspace_reference(directory string) (string, string) {
	head := run_workspace_git_command(directory, ['rev-parse', '--verify', 'HEAD']) or {
		return 'unavailable', 'committed-head-unavailable'
	}
	clean_head := head.trim_space()
	if !valid_git_object_id(clean_head) {
		return 'unavailable', 'committed-head-unavailable'
	}
	return 'git-head:${clean_head}', 'committed-head-only; dirty workspace state not captured'
}
