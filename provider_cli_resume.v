module main

// Native installed-CLI session resume (#691): Veasel's store remains the
// canonical history (ADR-0001); the CLI's own session/thread id is kept
// per (Veasel session, provider) purely as a continuation optimization.
// A stored id is only ever used when it is argv-safe, a failed resume
// clears it and the caller retries once with the flattened canonical
// transcript, and continuity never depends on the CLI's session store.

pub fn is_safe_cli_session_id(id string) bool {
	if id.len == 0 || id.len > 128 || id.starts_with('-') {
		return false
	}
	for ch in id {
		if !((ch >= `a` && ch <= `z`) || (ch >= `A` && ch <= `Z`)
			|| (ch >= `0` && ch <= `9`) || ch == `-` || ch == `_` || ch == `.`) {
			return false
		}
	}
	return true
}

fn (mut store Store) get_cli_resume_id(session_id string, provider string) string {
	store.mu.lock()
	defer { store.mu.unlock() }
	rows := store.db.exec_param_many('SELECT cli_session_id FROM session_cli_resume WHERE session_id = ? AND provider = ?',
		[session_id, provider]) or { return '' }
	if rows.len == 0 {
		return ''
	}
	id := rows[0].val(0)
	if !is_safe_cli_session_id(id) {
		return ''
	}
	return id
}

fn (mut store Store) set_cli_resume_id(session_id string, provider string, cli_session_id string) ! {
	if !is_safe_cli_session_id(cli_session_id) {
		return error('refusing to store an unsafe CLI session id')
	}
	store.mu.lock()
	defer { store.mu.unlock() }
	_ = store.db.exec_param_many('INSERT INTO session_cli_resume (session_id, provider, cli_session_id, updated_at) VALUES (?, ?, ?, CURRENT_TIMESTAMP) ON CONFLICT(session_id, provider) DO UPDATE SET cli_session_id = excluded.cli_session_id, updated_at = CURRENT_TIMESTAMP',
		[session_id, provider, cli_session_id]) or {
		return error('unable to store CLI session resume id')
	}
}

fn (mut store Store) clear_cli_resume_id(session_id string, provider string) ! {
	store.mu.lock()
	defer { store.mu.unlock() }
	_ = store.db.exec_param_many('DELETE FROM session_cli_resume WHERE session_id = ? AND provider = ?',
		[session_id, provider]) or { return error('unable to clear CLI session resume id') }
}

// cli_resume_prompt is the only text a resumed CLI turn receives: the
// CLI already holds the earlier context in its own session. Without a
// resume id the caller sends the full flattened transcript instead.
pub fn cli_resume_prompt(messages []ChatMessage) string {
	for index := messages.len - 1; index >= 0; index-- {
		message := messages[index]
		if message.role == 'user' && message.content.trim_space().len > 0 {
			return message.content
		}
	}
	return ''
}
