module main

import os
import rand

fn test_cli_tool_approval_lifecycle() {
	root := os.join_path(os.temp_dir(), 'veasel-cli-approvals-${rand.ulid()}')
	defer { os.rmdir_all(root) or {} }
	os.mkdir_all(root) or { panic(err) }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{
		title:     'approvals'
		directory: root
	}) or { panic(err) }

	approval := store.create_cli_tool_approval(session.id, 'req-1', 'Bash',
		'{"command":"ls"}') or { panic(err) }
	assert approval.status == 'pending'
	assert approval.tool_name == 'Bash'

	pending := store.list_pending_cli_tool_approvals(session.id) or { panic(err) }
	assert pending.len == 1
	assert pending[0].id == approval.id

	decided := store.decide_cli_tool_approval(session.id, approval.id, true) or {
		panic(err)
	}
	assert decided.status == 'approved'
	assert store.list_pending_cli_tool_approvals(session.id) or { panic(err) }.len == 0

	// Deciding twice must fail: a stale client cannot flip a settled row.
	if _ := store.decide_cli_tool_approval(session.id, approval.id, false) {
		panic('second decision must fail')
	}
	// Approvals are session-scoped.
	other := store.create_session(SessionInput{
		title:     'other'
		directory: root
	}) or { panic(err) }
	foreign := store.create_cli_tool_approval(session.id, 'req-2', 'Edit', '{}') or {
		panic(err)
	}
	if _ := store.decide_cli_tool_approval(other.id, foreign.id, true) {
		panic('cross-session decision must fail')
	}
	store.expire_cli_tool_approval(foreign.id) or { panic(err) }
	expired := store.get_cli_tool_approval(foreign.id) or { panic(err) }
	assert expired.status == 'expired'
}
