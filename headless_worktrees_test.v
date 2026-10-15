module main

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
