module main

import db.sqlite
import uuid

// Durable interactive approvals for installed-CLI tool calls (#691).
// When a CLI turn runs in interactive mode, each can_use_tool request
// becomes a pending row here; the turn polls until a client (TUI via
// the HTTP API) approves or denies it, or the approval deadline expires
// it. Nothing is ever auto-approved: expiry and absence of a decider
// both mean deny (fail closed).

pub struct CliToolApproval {
pub:
	id         string
	session_id string
	request_id string
	tool_name  string
	input_json string
	status     string // pending|approved|denied|expired
	created_at string
	updated_at string
}

fn cli_tool_approval_from_row(row sqlite.Row) CliToolApproval {
	return CliToolApproval{
		id:         row.val(0)
		session_id: row.val(1)
		request_id: row.val(2)
		tool_name:  row.val(3)
		input_json: row.val(4)
		status:     row.val(5)
		created_at: row.val(6)
		updated_at: row.val(7)
	}
}

const cli_tool_approval_columns = 'id, session_id, request_id, tool_name, input_json, status, created_at, updated_at'

fn (mut store Store) create_cli_tool_approval(session_id string, request_id string,
	tool_name string, input_json string) !CliToolApproval {
	_ := store.get_session(session_id) or {
		return error('session not found')
	}
	id := uuid.new_v4().str()
	_ = store.db.exec_param_many('INSERT INTO cli_tool_approvals (${cli_tool_approval_columns}) VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)',
		[id, session_id, request_id, tool_name, input_json, 'pending']) or {
		return error('unable to record CLI tool approval')
	}
	return store.get_cli_tool_approval(id)!
}

fn (mut store Store) get_cli_tool_approval(id string) !CliToolApproval {
	rows := store.db.exec_param_many('SELECT ${cli_tool_approval_columns} FROM cli_tool_approvals WHERE id = ?',
		[id]) or { return error('unable to read CLI tool approval') }
	if rows.len == 0 {
		return error('CLI tool approval not found')
	}
	return cli_tool_approval_from_row(rows[0])
}

fn (mut store Store) list_pending_cli_tool_approvals(session_id string) ![]CliToolApproval {
	rows := store.db.exec_param_many('SELECT ${cli_tool_approval_columns} FROM cli_tool_approvals WHERE session_id = ? AND status = ? ORDER BY created_at ASC',
		[session_id, 'pending']) or {
		return error('unable to list CLI tool approvals')
	}
	mut approvals := []CliToolApproval{cap: rows.len}
	for row in rows {
		approvals << cli_tool_approval_from_row(row)
	}
	return approvals
}

// decide_cli_tool_approval records an explicit human decision. Only a
// pending approval can be decided; deciding twice is an error so a
// stale client can never flip a settled approval.
fn (mut store Store) decide_cli_tool_approval(session_id string, id string,
	approved bool) !CliToolApproval {
	current := store.get_cli_tool_approval(id) or {
		return error('CLI tool approval not found')
	}
	if current.session_id != session_id {
		return error('CLI tool approval not found')
	}
	if current.status != 'pending' {
		return error('CLI tool approval is already ${current.status}')
	}
	status := if approved { 'approved' } else { 'denied' }
	_ = store.db.exec_param_many('UPDATE cli_tool_approvals SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND status = ?',
		[status, id, 'pending']) or {
		return error('unable to decide CLI tool approval')
	}
	return store.get_cli_tool_approval(id)!
}

fn (mut store Store) expire_cli_tool_approval(id string) ! {
	_ = store.db.exec_param_many('UPDATE cli_tool_approvals SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND status = ?',
		['expired', id, 'pending']) or {
		return error('unable to expire CLI tool approval')
	}
	return
}

// expire_pending_cli_tool_approvals settles every still-pending approval of a
// session as expired. Called when a turn ends (cancel, deadline, error) so no
// approval outlives the CLI process it belonged to.
fn (mut store Store) expire_pending_cli_tool_approvals(session_id string) ! {
	_ = store.db.exec_param_many('UPDATE cli_tool_approvals SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE session_id = ? AND status = ?',
		['expired', session_id, 'pending']) or {
		return error('unable to expire pending CLI tool approvals')
	}
}
