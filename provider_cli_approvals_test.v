module main

import os
import rand

fn read_cli_approvals_concurrently(store &Store, session_id string, iterations int,
	start chan bool, results chan bool) {
	mut local_store := store
	_ = <-start
	for _ in 0 .. iterations {
		if _ := local_store.get_session(session_id) {
		} else {
			results <- false
			return
		}
		if _ := local_store.list_pending_cli_tool_approvals(session_id) {
		} else {
			results <- false
			return
		}
		_ = local_store.get_cli_resume_id(session_id, 'codex')
	}
	results <- true
}

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

	review_json := '{"threadId":"parent","turnId":"turn-1","itemId":"edit-1","changes":[{"path":"src/main.v","kind":"update","diff":"@@ -1 +1 @@\\n-old\\n+new"}]}'
	approval := store.create_cli_tool_approval(session.id, 'req-1', 'Edit',
		review_json) or { panic(err) }
	assert approval.status == 'pending'
	assert approval.tool_name == 'Edit'

	pending := store.list_pending_cli_tool_approvals(session.id) or { panic(err) }
	assert pending.len == 1
	assert pending[0].id == approval.id
	assert pending[0].input_json == review_json
	assert pending[0].input_json.contains('src/main.v')
	assert pending[0].input_json.contains('+new')

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

fn test_cli_tool_approval_store_serializes_concurrent_reads_and_writes() {
	root := os.join_path(os.temp_dir(), 'veasel-cli-approval-concurrency-${rand.ulid()}')
	defer { os.rmdir_all(root) or {} }
	os.mkdir_all(root) or { panic(err) }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{
		title:     'approval concurrency'
		directory: root
	}) or { panic(err) }
	results := chan bool{cap: 2}
	start := chan bool{cap: 2}
	spawn read_cli_approvals_concurrently(store, session.id, 200, start, results)
	spawn read_cli_approvals_concurrently(store, session.id, 200, start, results)
	start <- true
	start <- true
	for index in 0 .. 200 {
		approval := store.create_cli_tool_approval(session.id, 'req-${index}', 'Bash', '{}') or {
			panic(err)
		}
		store.decide_cli_tool_approval(session.id, approval.id, true) or { panic(err) }
		store.set_cli_resume_id(session.id, 'codex', 'resume-${index}') or { panic(err) }
		if index % 2 == 0 {
			store.clear_cli_resume_id(session.id, 'codex') or { panic(err) }
		}
	}
	assert <-results
	assert <-results
	assert (store.list_pending_cli_tool_approvals(session.id) or { panic(err) }).len == 0
}
