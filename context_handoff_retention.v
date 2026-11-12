module main

import json2
import uuid

const max_retained_context_handoffs_per_session = 1000

// persist_context_handoff_retained creates and stores an application-owned
// handoff artifact in its own bounded table. The event copy is written in the
// same transaction for timeline visibility, so event pruning cannot erase the
// retrievable artifact.
fn (mut store Store) persist_context_handoff_retained(session_id string, next_operation_id string,
	target_provider string, target_model string, policy ExecutionPolicyTurn,
	policy_source string) !ContextHandoffArtifact {
	if !validate_operation_id(next_operation_id) {
		return error('context handoff operation identifier is invalid')
	}
	validate_context_handoff_route(target_provider, target_model)!
	if policy_source !in ['parent_turn', 'manual_user_action', 'recovered_operation'] {
		return error('context handoff permission provenance is invalid')
	}
	if prior := store.retained_context_handoff_for_operation(session_id, next_operation_id) {
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
	previous := store.latest_retained_context_handoff(session_id)!
	mut mode := 'full'
	mut base_message_id := 0
	mut fallback_reason := 'no prior handoff checkpoint; using a bounded full-context snapshot'
	mut messages := store.context_handoff_full_messages(session_id)!
	if previous.artifact_id.len > 0 {
		if previous.target_provider == source_operation.provider
			&& previous.target_model == source_operation.model {
			if previous.transcript_complete {
				mode = 'delta'
				base_message_id = previous.through_message_id
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
				fallback_reason = 'previous handoff checkpoint was incomplete; using a bounded full-context snapshot'
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
		first_message_id:             entries[0].message_id
		through_message_id:           entries[entries.len - 1].message_id
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
	store.persist_context_handoff_artifact(artifact)!
	return store.retained_context_handoff_for_operation(session_id, next_operation_id)!
}

fn (mut store Store) persist_context_handoff_artifact(artifact ContextHandoffArtifact) ! {
	encoded := json2.encode(artifact)
	if encoded.len == 0 || encoded.len > max_context_handoff_event_bytes {
		return error('context handoff artifact exceeds its storage bound')
	}
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	store.db.begin()!
	session := store.db.exec_param('SELECT id FROM sessions WHERE id = ?', artifact.session_id) or {
		store.db.rollback() or {}
		return error('session not found')
	}
	if session.len != 1 {
		store.db.rollback() or {}
		return error('session not found')
	}
	operation := store.db.exec_param_many('SELECT id FROM session_operations WHERE session_id = ? AND id = ?',
		[artifact.session_id, artifact.next_operation_id]) or {
		store.db.rollback() or {}
		return error('context handoff operation not found')
	}
	if operation.len != 1 {
		store.db.rollback() or {}
		return error('context handoff operation not found')
	}
	prior := store.db.exec_param_many('SELECT artifact_json FROM context_handoffs WHERE session_id = ? AND next_operation_id = ?',
		[artifact.session_id, artifact.next_operation_id]) or {
		store.db.rollback() or {}
		return error('unable to check context handoff idempotency')
	}
	if prior.len > 0 {
		prior_artifact := json2.decode[ContextHandoffArtifact](prior[0].val(0)) or {
			store.db.rollback() or {}
			return error('stored context handoff artifact is invalid')
		}
		store.db.rollback() or {}
		if prior_artifact.source_operation_id != artifact.source_operation_id
			|| prior_artifact.target_provider != artifact.target_provider
			|| prior_artifact.target_model != artifact.target_model
			|| prior_artifact.permission_policy_mode != artifact.permission_policy_mode
			|| prior_artifact.permission_interactive != artifact.permission_interactive
			|| prior_artifact.permission_policy_source != artifact.permission_policy_source {
			return error('context handoff operation was already recorded with different routing or permissions')
		}
		return
	}
	_ = store.db.exec_param_many('INSERT INTO context_handoffs (session_id, next_operation_id, artifact_json) VALUES (?, ?, ?)', [
		artifact.session_id,
		artifact.next_operation_id,
		encoded,
	]) or {
		store.db.rollback() or {}
		return error('unable to persist context handoff artifact')
	}
	_ = store.db.exec_param_many('INSERT INTO events (type, session_id, data) VALUES (?, ?, ?)', [
		context_handoff_event_type,
		artifact.session_id,
		json2.encode[EventData](EventData{
			delta: encoded
		}),
	]) or {
		store.db.rollback() or {}
		return error('unable to persist context handoff event')
	}
	_ = store.db.exec_param_many('DELETE FROM context_handoffs WHERE session_id = ? AND rowid NOT IN (SELECT rowid FROM context_handoffs WHERE session_id = ? ORDER BY created_at DESC, rowid DESC LIMIT ?)', [
		artifact.session_id,
		artifact.session_id,
		max_retained_context_handoffs_per_session.str(),
	]) or {
		store.db.rollback() or {}
		return error('unable to prune retained context handoffs')
	}
	store.db.commit() or {
		store.db.rollback() or {}
		return error('unable to commit context handoff artifact')
	}
	store.prune_session_events_unlocked(artifact.session_id)
}

fn (mut store Store) retained_context_handoff_for_operation(session_id string,
	next_operation_id string) !ContextHandoffArtifact {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	rows := store.db.exec_param_many('SELECT created_at, artifact_json FROM context_handoffs WHERE session_id = ? AND next_operation_id = ?',
		[session_id, next_operation_id])!
	if rows.len != 1 {
		return error('context handoff artifact not found')
	}
	mut artifact := json2.decode[ContextHandoffArtifact](rows[0].val(1)) or {
		return error('stored context handoff artifact is invalid')
	}
	artifact.created_at = rows[0].val(0)
	return artifact
}

fn (mut store Store) latest_retained_context_handoff(session_id string) !ContextHandoffArtifact {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	rows := store.db.exec_param_many('SELECT created_at, artifact_json FROM context_handoffs WHERE session_id = ? ORDER BY created_at DESC, rowid DESC LIMIT 1',
		[session_id])!
	if rows.len == 0 {
		return ContextHandoffArtifact{}
	}
	mut artifact := json2.decode[ContextHandoffArtifact](rows[0].val(1)) or {
		return error('stored context handoff artifact is invalid')
	}
	artifact.created_at = rows[0].val(0)
	return artifact
}

fn (mut store Store) list_retained_context_handoffs(session_id string) ![]ContextHandoffArtifact {
	store.mu.lock()
	defer {
		store.mu.unlock()
	}
	rows := store.db.exec_param_many('SELECT created_at, artifact_json FROM context_handoffs WHERE session_id = ? ORDER BY created_at ASC, rowid ASC',
		[session_id])!
	mut artifacts := []ContextHandoffArtifact{cap: rows.len}
	for row in rows {
		mut artifact := json2.decode[ContextHandoffArtifact](row.val(1)) or {
			return error('stored context handoff artifact is invalid')
		}
		artifact.created_at = row.val(0)
		artifacts << artifact
	}
	return artifacts
}
