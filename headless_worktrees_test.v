module main

import net.http
import time

struct WorktreesSessionFixture {}

fn (mut _ WorktreesSessionFixture) handle(request http.Request) http.Response {
	mut response := http.Response{}
	if request.url == '/v1/sessions' {
		// POST /v1/sessions answers 201 Created, like the real API.
		response.set_status(.created)
		response.header.set(.content_type, 'application/json')
		response.body = '{"id":"sess-created","title":"Veasel worktrees","directory":"/tmp","created_at":""}'
		return response
	}
	response.set_status(.not_found)
	return response
}

fn test_headless_worktrees_resolves_session_from_created_response() {
	// Regression: resolve_headless_worktrees_session required HTTP 200
	// from POST /v1/sessions, but the API answers 201 Created, so every
	// `veasel worktrees` invocation without --session failed with the
	// opaque "HTTP 201" instead of listing worktrees.
	mut fixture := &WorktreesSessionFixture{}
	mut server := &http.Server{
		accept_timeout:       100 * time.millisecond
		handler:              fixture
		addr:                 '127.0.0.1:0'
		show_startup_message: false
	}
	server_thread := spawn server.listen_and_serve()
	server.wait_till_running() or {
		server.stop()
		server_thread.wait()
		panic(err)
	}
	defer {
		server.stop()
		server_thread.wait()
	}
	port := server.addr.all_after_last(':').int()
	assert port > 0
	id := resolve_headless_worktrees_session(port, HeadlessWorktreesOptions{
		workspace: '/tmp'
	}) or { panic(err) }
	assert id == 'sess-created'
}

fn test_headless_worktrees_parses_list_add_remove() {
	listed := parse_headless_worktrees_args(['list', '-w', '/tmp/ws', '--json'], '/tmp') or {
		panic(err)
	}
	assert listed.action == .list
	assert listed.workspace == '/tmp/ws'
	assert listed.json

	added := parse_headless_worktrees_args([
		'add',
		'--path',
		'/tmp/wt',
		'--new-branch',
		'feature/x',
		'--session',
		'123e4567-e89b-42d3-a456-426614174000',
	], '/tmp') or { panic(err) }
	assert added.action == .add
	assert added.path == '/tmp/wt'
	assert added.new_branch == 'feature/x'
	assert added.session_id == '123e4567-e89b-42d3-a456-426614174000'

	removed := parse_headless_worktrees_args(['remove', '--path', '/tmp/wt', '--force'],
		'/tmp') or { panic(err) }
	assert removed.action == .remove
	assert removed.force

	locked := parse_headless_worktrees_args(['lock', '--path', '/tmp/wt', '--reason', 'hold'],
		'/tmp') or { panic(err) }
	assert locked.action == .lock
	assert locked.reason == 'hold'
	unlocked := parse_headless_worktrees_args(['unlock', '--path', '/tmp/wt'], '/tmp') or {
		panic(err)
	}
	assert unlocked.action == .unlock
}

fn test_headless_worktrees_rejects_invalid_shapes() {
	if _ := parse_headless_worktrees_args(['add', '--path', '/tmp/wt'], '/tmp') {
		assert false
	} else {
		assert err.msg().contains('branch')
	}
	if _ := parse_headless_worktrees_args(['remove'], '/tmp') {
		assert false
	} else {
		assert err.msg().contains('--path')
	}
	if _ := parse_headless_worktrees_args(['unlock', '--path', '/tmp/wt', '--reason', 'x'],
		'/tmp') {
		assert false
	} else {
		assert err.msg().contains('--reason')
	}
	if _ := parse_headless_worktrees_args(['mystery'], '/tmp') {
		assert false
	} else {
		assert err.msg().contains('unknown worktrees command')
	}
}
