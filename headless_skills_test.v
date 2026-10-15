module main

fn test_headless_skills_parses_list() {
	listed := parse_headless_skills_args(['list', '-w', '/tmp/project', '--json'], '/tmp') or {
		panic(err)
	}
	assert listed.directory == '/tmp/project'
	assert listed.json
}

fn test_headless_skills_rejects_invalid() {
	if _ := parse_headless_skills_args(['enable'], '/tmp') {
		assert false
	} else {
		assert err.msg().contains('unknown skills command')
	}
	if _ := parse_headless_skills_args(['list', '--mystery'], '/tmp') {
		assert false
	} else {
		assert err.msg().contains('unknown skills option')
	}
}
