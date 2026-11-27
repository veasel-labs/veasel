module main

import json2
import net
import net.http
import os
import time
import uuid
import veb

// ---------------------------------------------------------------- fixtures

struct AuthTestServerSlot {
	ready chan &veb.Server
}

const auth_test_slot = &AuthTestServerSlot{
	ready: chan &veb.Server{cap: 1}
}

// Test-build only: lets the suite stop the real App it serves.
pub fn (mut app App) init_server(server &veb.Server) {
	auth_test_slot.ready <- server
}

fn run_auth_test_app(mut app App, port int) {
	veb.run_at[App, Context](mut app, host: '127.0.0.1', family: .ip, port: port) or { panic(err) }
}

fn auth_test_free_port() int {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	port := listener.addr() or { panic(err) }.port() or { panic(err) }
	listener.close() or { panic(err) }
	return port
}

fn auth_test_root() string {
	root := os.join_path(os.temp_dir(), 'veasel-auth-${uuid.new_v4().str()}')
	os.mkdir_all(root, mode: 0o700) or { panic(err) }
	return root
}

// Sends raw bytes so Host, method, and path spellings are exactly what the
// test wrote, not what an HTTP client library normalizes. Returns whatever
// arrived before EOF or the read timeout.
fn auth_test_raw(port int, request string) string {
	// A reset before the first byte is a transport hiccup, not a verdict
	// (the verdict is always a full HTTP status line), so retry briefly.
	mut response := ''
	for _ in 0 .. 4 {
		response = auth_test_raw_once(port, request)
		if response.len > 0 {
			break
		}
		time.sleep(50 * time.millisecond)
	}
	return response
}

fn auth_test_raw_once(port int, request string) string {
	mut conn := net.dial_tcp('127.0.0.1:${port}') or { panic(err) }
	defer {
		conn.close() or {}
	}
	conn.set_read_timeout(1500 * time.millisecond)
	conn.write_string(request) or { return '' }
	mut out := []u8{}
	mut buf := []u8{len: 4096}
	for {
		n := conn.read(mut buf) or { break }
		if n <= 0 {
			break
		}
		out << buf[..n]
		if out.len > 1 << 20 {
			break
		}
	}
	return out.bytestr()
}

fn auth_test_status(response string) string {
	return response.all_before('\r\n')
}

fn auth_test_request(method string, path string, headers []string) string {
	mut request := '${method} ${path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n'
	for header in headers {
		request += header + '\r\n'
	}
	return request + '\r\n'
}

// Replaces `:param` segments with a dummy value so every declared route
// can be requested.
fn auth_test_route_table() []string {
	mut routes := []string{}
	dir := os.dir(@FILE)
	for file in os.ls(dir) or { panic(err) } {
		if !file.ends_with('.v') || file.ends_with('_test.v') {
			continue
		}
		for line in os.read_lines(os.join_path(dir, file)) or { panic(err) } {
			if !line.starts_with("@['/") {
				continue
			}
			inner := line.all_after("@['").all_before(']')
			parts := inner.split(';').map(it.trim_space().trim("'"))
			path := parts[0]
			mut methods := parts[1..].filter(it in ['get', 'post', 'put', 'delete', 'patch', 'head',
				'options'])
			if methods.len == 0 {
				methods = ['get']
			}
			mut concrete := []string{}
			for segment in path.split('/') {
				concrete << if segment.starts_with(':') { 'canary' } else { segment }
			}
			for method in methods {
				routes << '${method.to_upper()} ${concrete.join('/')}'
			}
		}
	}
	return routes
}

// ------------------------------------------------------------ token unit tests

fn test_generated_token_is_256_bit_hex_and_unique() {
	a := generate_api_token() or { panic(err) }
	b := generate_api_token() or { panic(err) }
	assert a.len == 64
	assert is_valid_generated_token(a)
	assert a != b
	assert !is_valid_generated_token(a[..63])
	assert !is_valid_generated_token(a.to_upper())
	assert !is_valid_generated_token('')
}

fn test_env_token_validation_rejects_short_and_unsafe_values() {
	assert is_valid_env_token('x'.repeat(32))
	assert !is_valid_env_token('x'.repeat(31))
	assert !is_valid_env_token('x'.repeat(513))
	assert !is_valid_env_token('x'.repeat(31) + ' ')
	assert !is_valid_env_token('x'.repeat(31) + '\n')
	assert !is_valid_env_token('x'.repeat(31) + 'é')
}

fn test_verifier_fails_closed_and_is_exact() {
	mut state := &APIAuthState{}
	assert !state.verify('anything')
	assert !state.verify('')
	state.configure('s'.repeat(64), '', true)
	assert state.verify('s'.repeat(64))
	assert !state.verify('s'.repeat(63))
	assert !state.verify('s'.repeat(65))
	assert !state.verify('S'.repeat(64))
	assert !state.verify('')
	state.reset()
	assert !state.verify('s'.repeat(64))
}

fn test_bearer_parsing_accepts_exactly_one_bearer_header() {
	mut ok := http.new_header()
	ok.add(.authorization, 'Bearer abc')
	assert bearer_token_from_request(ok) == 'abc'
	mut lower := http.new_header()
	lower.add(.authorization, 'bearer abc')
	assert bearer_token_from_request(lower) == 'abc'
	mut basic := http.new_header()
	basic.add(.authorization, 'Basic abc')
	assert bearer_token_from_request(basic) == ''
	mut bare := http.new_header()
	bare.add(.authorization, 'abc')
	assert bearer_token_from_request(bare) == ''
	mut twice := http.new_header()
	twice.add(.authorization, 'Bearer abc')
	twice.add(.authorization, 'Bearer abc')
	assert bearer_token_from_request(twice) == ''
	assert bearer_token_from_request(http.new_header()) == ''
}

fn test_only_exact_get_health_is_liveness_exempt() {
	assert is_unauthenticated_liveness_request(.get, '/v1/health')
	assert is_unauthenticated_liveness_request(.get, '/v1/health?x=1')
	assert !is_unauthenticated_liveness_request(.post, '/v1/health')
	assert !is_unauthenticated_liveness_request(.head, '/v1/health')
	assert !is_unauthenticated_liveness_request(.options, '/v1/health')
	assert !is_unauthenticated_liveness_request(.get, '/v1/health/')
	assert !is_unauthenticated_liveness_request(.get, '/V1/health')
	assert !is_unauthenticated_liveness_request(.get, '/v1/Health')
	assert !is_unauthenticated_liveness_request(.get, '//v1/health')
	assert !is_unauthenticated_liveness_request(.get, '/v1/%68ealth')
	assert !is_unauthenticated_liveness_request(.get, 'http://127.0.0.1/v1/health')
	assert !is_unauthenticated_liveness_request(.get, '/v1/capabilities')
}

// Regression: a Windows directory contains backslashes, which are JSON
// escapes. Session-create bodies must be encoded, never interpolated, or
// `C:\Users\...` becomes invalid JSON and the server rightly returns 400.
fn test_session_input_encoding_round_trips_windows_directory() {
	windows_root := 'C:\\Users\\runneradmin\\AppData\\Local\\Temp\\veasel-auth-1234'
	body := json2.encode(SessionInput{
		title:     'authed'
		directory: windows_root
	})
	decoded := json2.decode[SessionInput](body) or { panic(err) }
	assert decoded.title == 'authed'
	assert decoded.directory == windows_root
}

// ------------------------------------------------------ token file lifecycle

fn test_token_file_is_created_private_and_reused_across_restarts() {
	root := auth_test_root()
	defer { os.rmdir_all(root) or {} }
	data := os.join_path(root, 'nested', 'data')
	first := load_or_create_api_token(data) or { panic(err) }
	path := api_token_path(data)
	assert is_valid_generated_token(first)
	$if !windows {
		assert os.stat(path) or { panic(err) }.mode & 0o777 == 0o600
		assert os.stat(data) or { panic(err) }.mode & 0o777 == 0o700
	}
	second := load_or_create_api_token(data) or { panic(err) }
	assert second == first
	assert os.ls(data) or { panic(err) } == ['api-token']
	assert discover_api_token_for_test(data) == first
}

fn discover_api_token_for_test(data string) string {
	prior := os.getenv_opt(api_token_env)
	os.unsetenv(api_token_env)
	defer {
		if value := prior {
			os.setenv(api_token_env, value, true)
		}
	}
	return discover_api_token(data) or { '' }
}

fn test_token_file_with_group_or_world_access_is_refused() {
	$if windows {
		return
	}
	root := auth_test_root()
	defer { os.rmdir_all(root) or {} }
	token := load_or_create_api_token(root) or { panic(err) }
	path := api_token_path(root)
	for mode in [0o640, 0o604, 0o644, 0o660, 0o666, 0o604] {
		os.chmod(path, mode) or { panic(err) }
		if _ := load_or_create_api_token(root) {
			assert false, 'mode ${mode.hex()} must be refused'
		}
		assert discover_api_token_for_test(root) == ''
	}
	os.chmod(path, 0o600) or { panic(err) }
	assert load_or_create_api_token(root) or { panic(err) } == token
}

fn test_symlinked_token_file_is_refused() {
	$if windows {
		return
	}
	root := auth_test_root()
	defer { os.rmdir_all(root) or {} }
	target := os.join_path(root, 'elsewhere')
	os.write_file(target, 'a'.repeat(64) + '\n') or { panic(err) }
	os.chmod(target, 0o600) or { panic(err) }
	os.symlink(target, api_token_path(root)) or { panic(err) }
	if _ := load_or_create_api_token(root) {
		assert false, 'a symlinked token must be refused'
	}
}

fn test_malformed_private_token_file_is_replaced_atomically() {
	root := auth_test_root()
	defer { os.rmdir_all(root) or {} }
	path := api_token_path(root)
	os.write_file(path, 'abc') or { panic(err) } // truncated by a crash or full disk
	os.chmod(path, 0o600) or {}
	token := load_or_create_api_token(root) or { panic(err) }
	assert is_valid_generated_token(token)
	assert os.read_file(path) or { panic(err) }.trim_space() == token
}

fn test_stale_temporaries_from_a_crashed_process_are_removed_and_ignored() {
	root := auth_test_root()
	defer { os.rmdir_all(root) or {} }
	stale := os.join_path(root, 'api-token.tmp-1-deadbeef')
	unrelated := os.join_path(root, 'veasel.sqlite3')
	os.write_file(stale, 'partial') or { panic(err) }
	os.write_file(unrelated, 'keep') or { panic(err) }
	// A fresh temporary may belong to a live server starting right now:
	// the production window leaves it alone, and startup never uses it.
	token := load_or_create_api_token(root) or { panic(err) }
	assert is_valid_generated_token(token)
	assert os.exists(stale)
	// Once older than the window it is removed; other files are untouched.
	remove_stale_token_temporaries(root, -1)
	assert !os.exists(stale)
	assert os.exists(unrelated)
	assert os.exists(api_token_path(root))
}

fn test_group_writable_data_directory_is_restricted() {
	$if windows {
		return
	}
	root := auth_test_root()
	defer { os.rmdir_all(root) or {} }
	os.chmod(root, 0o777) or { panic(err) }
	load_or_create_api_token(root) or { panic(err) }
	assert os.stat(root) or { panic(err) }.mode & 0o022 == 0
}

fn test_rotation_replaces_file_and_live_verifier() {
	prior := os.getenv_opt(api_token_env)
	os.unsetenv(api_token_env)
	defer {
		if value := prior {
			os.setenv(api_token_env, value, true)
		}
	}
	root := auth_test_root()
	defer { os.rmdir_all(root) or {} }
	init_api_auth(root) or { panic(err) }
	mut state := api_auth_state()
	old_token := read_token_file(api_token_path(root)) or { panic(err) }
	assert state.verify(old_token)
	rotate_api_token() or { panic(err) }
	new_token := read_token_file(api_token_path(root)) or { panic(err) }
	assert new_token != old_token
	assert state.verify(new_token)
	assert !state.verify(old_token)
	state.reset()
}

fn test_env_token_overrides_file_and_blocks_rotation() {
	prior := os.getenv_opt(api_token_env)
	defer {
		if value := prior {
			os.setenv(api_token_env, value, true)
		} else {
			os.unsetenv(api_token_env)
		}
	}
	root := auth_test_root()
	defer { os.rmdir_all(root) or {} }
	os.setenv(api_token_env, 'E'.repeat(40), true)
	init_api_auth(root) or { panic(err) }
	mut state := api_auth_state()
	assert state.verify('E'.repeat(40))
	assert !os.exists(api_token_path(root))
	if _ := rotate_api_token() {
		assert false, 'env-managed tokens cannot be rotated in place'
	}
	os.setenv(api_token_env, 'short', true)
	if _ := init_api_auth(root) {
		assert false, 'a short env token must be rejected'
	}
	state.reset()
}

// ------------------------------------------------- HTTP: real App, real routes

fn test_every_declared_route_rejects_unauthenticated_requests_and_runs_no_handler() {
	prior := os.getenv_opt(api_token_env)
	os.unsetenv(api_token_env)
	defer {
		if value := prior {
			os.setenv(api_token_env, value, true)
		}
	}
	root := auth_test_root()
	defer { os.rmdir_all(root) or {} }
	data := os.join_path(root, 'data')
	init_api_auth(data) or { panic(err) }
	mut state := api_auth_state()
	defer { state.reset() }
	token := read_token_file(api_token_path(data)) or { panic(err) }

	mut store := open_store(os.join_path(data, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	plugin_dir := os.join_path(data, 'plugins')
	os.mkdir_all(plugin_dir) or { panic(err) }
	mut app := new_app(store, plugin_dir)
	defer { app.close() }
	port := auth_test_free_port()
	server_thread := spawn run_auth_test_app(mut app, port)
	server := <-auth_test_slot.ready
	server.wait_till_running() or { panic(err) }
	defer {
		server.shutdown(timeout: 5 * time.second) or {}
		server_thread.wait()
	}

	routes := auth_test_route_table()
	assert routes.len >= 80
	assert 'POST /v1/auth/rotate' in routes
	assert 'GET /v1/events' in routes
	assert 'GET /v1/sessions/canary/events' in routes
	assert 'GET /v1/sessions/canary/workspace/files' in routes
	mut exempt := 0
	for route in routes {
		method := route.all_before(' ')
		path := route.all_after(' ')
		if route == 'GET /v1/health' {
			exempt++
			continue
		}
		body := if method in ['POST', 'PATCH', 'PUT'] { '{}' } else { '' }
		length := if body.len > 0 { 'Content-Length: ${body.len}' } else { 'Content-Length: 0' }
		response := auth_test_raw(port, auth_test_request(method, path, [length,
			'Content-Type: application/json']).trim_right('\r\n') + '\r\n\r\n${body}')
		assert auth_test_status(response).contains(' 401 '), '${route} unauthenticated -> ${auth_test_status(response)}'
		assert response.contains('WWW-Authenticate: Bearer')
		assert !response.contains(token)
		// A wrong token never works either.
		wrong := auth_test_raw(port, auth_test_request(method, path, [
			'Authorization: Bearer ${'0'.repeat(64)}',
			length,
		]).trim_right('\r\n') + '\r\n\r\n${body}')
		assert auth_test_status(wrong).contains(' 401 '), '${route} wrong token -> ${auth_test_status(wrong)}'
	}
	assert exempt == 1

	// Canary: no handler body ran, so nothing was created or rotated.
	sessions := store.list_sessions() or { panic(err) }
	assert sessions.len == 0
	assert read_token_file(api_token_path(data)) or { panic(err) } == token

	assert 'POST /v1/goals' in routes
	assert 'GET /v1/goals/canary/preflight' in routes
	assert 'GET /v1/goals/canary' in routes
	assert 'GET /v1/goals/canary/tasks' in routes
	assert 'POST /v1/goals/canary/tasks/canary/start' in routes
	admission_rows := store.admitted_goals() or { panic(err) }
	assert admission_rows.len == 0
	auth_test_goal_round_trip(port, token)

	// Truncated, extended, wrong-scheme, and query-string credentials.
	for headers in [
		['Authorization: Bearer ${token[..63]}'],
		['Authorization: Bearer ${token}0'],
		['Authorization: Bearer ${token.to_upper()}'],
		['Authorization: Basic ${token}'],
		['Authorization: ${token}'],
		['Authorization: Bearer ${token}', 'Authorization: Bearer ${token}'],
		['Authorization: Bearer'],
		['Authorization: Bearer '],
		['X-Veasel-Token: ${token}'],
		['Cookie: token=${token}'],
	] {
		response := auth_test_raw(port, auth_test_request('GET', '/v1/sessions', headers))
		assert auth_test_status(response).contains(' 401 '), '${headers} -> ${auth_test_status(response)}'
	}
	query := auth_test_raw(port, auth_test_request('GET', '/v1/sessions?token=${token}&access_token=${token}',
		[]))
	assert auth_test_status(query).contains(' 401 ')

	// Path/method spellings never bypass the gate (veb may 404/405 them only
	// after authentication).
	for variant in [
		'GET /v1/sessions/',
		'GET /V1/SESSIONS',
		'GET //v1/sessions',
		'GET /v1/sessions/..;/health',
		'GET /v1/health/',
		'GET /v1/Health',
		'GET /v1/%68ealth',
		'GET /v1/nonexistent',
		'GET /',
		'GET /index.html',
		'GET /v1/sessions#',
		'HEAD /v1/sessions',
		'HEAD /v1/health',
		'OPTIONS /v1/sessions',
		'OPTIONS /v1/health',
		'OPTIONS *',
		'PUT /v1/sessions',
		'DELETE /v1/sessions',
		'TRACE /v1/sessions',
		'POST /v1/health',
		'POST /v1/events',
		'GET http://127.0.0.1/v1/sessions',
		'GET http://127.0.0.1/v1/health',
		'BREW /v1/sessions',
	] {
		response := auth_test_raw(port, '${variant} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n')
		status := auth_test_status(response)
		assert status.contains(' 401 ') || status.contains(' 400 '), '${variant} -> ${status}'
	}

	// SSE without a token is rejected before any event frame is written.
	sse := auth_test_raw(port, auth_test_request('GET', '/v1/events', ['Accept: text/event-stream']))
	assert auth_test_status(sse).contains(' 401 ')
	assert !sse.contains('text/event-stream')
	assert !sse.contains('event:')

	// DNS rebinding and cross-origin attempts are refused even with a token.
	bearer := 'Authorization: Bearer ${token}'
	rebind := auth_test_raw(port, 'GET /v1/sessions HTTP/1.1\r\nHost: evil.example\r\n${bearer}\r\nConnection: close\r\n\r\n')
	assert auth_test_status(rebind).contains(' 403 ')
	rebind_port := auth_test_raw(port, 'GET /v1/sessions HTTP/1.1\r\nHost: evil.example:${port}\r\n${bearer}\r\nConnection: close\r\n\r\n')
	assert auth_test_status(rebind_port).contains(' 403 ')
	cross := auth_test_raw(port, auth_test_request('GET', '/v1/sessions', [bearer,
		'Origin: https://evil.example']))
	assert auth_test_status(cross).contains(' 403 ')
	null_origin := auth_test_raw(port, auth_test_request('GET', '/v1/sessions', [
		bearer,
		'Origin: null',
	]))
	assert auth_test_status(null_origin).contains(' 403 ')
	cross_noauth := auth_test_raw(port, auth_test_request('GET', '/v1/sessions', [
		'Origin: https://evil.example',
	]))
	assert auth_test_status(cross_noauth).contains(' 403 ')
	// A page on a loopback origin still cannot call without the secret.
	loopback_page := auth_test_raw(port, auth_test_request('GET', '/v1/sessions', [
		'Origin: http://127.0.0.1:9',
	]))
	assert auth_test_status(loopback_page).contains(' 401 ')

	// Liveness: minimal and leak-free without a token.
	live := auth_test_raw(port, auth_test_request('GET', '/v1/health', []))
	assert auth_test_status(live).contains(' 200 ')
	assert live.all_after('\r\n\r\n') == '{"healthy":true,"auth":"bearer","protocol":1}'
	assert !live.contains('pid')
	assert !live.contains('version')

	// Correct token works on every method family, with and without a
	// loopback Origin, and rich health is available behind it.
	rich := http.fetch(
		url:    'http://127.0.0.1:${port}/v1/health'
		header: auth_test_header(token)
	) or { panic(err) }
	health := json2.decode[Health](rich.body) or { panic(err) }
	assert health.healthy
	assert health.pid == os.getpid()
	assert health.version == product_version
	listed := http.fetch(
		url:    'http://127.0.0.1:${port}/v1/sessions'
		header: auth_test_header(token)
	) or { panic(err) }
	assert listed.status_code == 200
	with_origin := auth_test_raw(port, auth_test_request('GET', '/v1/sessions', [
		bearer,
		'Origin: http://localhost:5173',
	]))
	assert auth_test_status(with_origin).contains(' 200 ')
	created := http.fetch(
		url:    'http://127.0.0.1:${port}/v1/sessions'
		method: .post
		header: auth_test_header(token)
		data:   json2.encode(SessionInput{
			title:     'authed'
			directory: root
		})
	) or { panic(err) }
	assert created.status_code in [200, 201], 'create session -> ${created.status_code} ${created.body}'
	// SSE with a token opens the stream.
	stream := auth_test_raw(port, auth_test_request('GET', '/v1/events', [bearer]))
	assert auth_test_status(stream).contains(' 200 ')

	// Rotation: the old token is replayed and must fail; the new one works.
	rotated := http.fetch(
		url:    'http://127.0.0.1:${port}/v1/auth/rotate'
		method: .post
		header: auth_test_header(token)
	) or { panic(err) }
	assert rotated.status_code == 200
	assert !rotated.body.contains(token)
	replay := auth_test_raw(port, auth_test_request('GET', '/v1/sessions', [bearer]))
	assert auth_test_status(replay).contains(' 401 ')
	fresh := read_token_file(api_token_path(data)) or { panic(err) }
	assert fresh != token
	again := http.fetch(
		url:    'http://127.0.0.1:${port}/v1/sessions'
		header: auth_test_header(fresh)
	) or { panic(err) }
	assert again.status_code == 200
	replay_rotate := auth_test_raw(port, auth_test_request('POST', '/v1/auth/rotate', [
		bearer,
		'Content-Length: 0',
	]))
	assert auth_test_status(replay_rotate).contains(' 401 ')
}

fn auth_test_header(token string) http.Header {
	mut header := http.new_header()
	header.set(.authorization, 'Bearer ${token}')
	return header
}

// ------------------------------------------- HTTP: handler never runs on failure

struct AuthCanaryServer {
	root  string
	port  int
	ready chan &veb.Server
}

pub fn (mut app AuthCanaryServer) init_server(server &veb.Server) {
	app.ready <- server
}

@['/v1/canary'; get; post; put; delete; patch; head; options]
pub fn (app &AuthCanaryServer) canary(mut ctx Context) veb.Result {
	os.write_file(os.join_path(app.root, 'canary-ran'), 'ran') or {}
	return ctx.text('ran')
}

fn run_auth_canary_server(mut app AuthCanaryServer) {
	veb.run_at[AuthCanaryServer, Context](mut app, host: '127.0.0.1', family: .ip, port: app.port) or {
		panic(err)
	}
}

fn test_canary_handler_body_never_executes_without_valid_credentials() {
	root := auth_test_root()
	defer { os.rmdir_all(root) or {} }
	mut state := api_auth_state()
	state.configure('c'.repeat(64), '', true)
	defer { state.reset() }
	port := auth_test_free_port()
	mut app := &AuthCanaryServer{
		root:  root
		port:  port
		ready: chan &veb.Server{cap: 1}
	}
	canary_thread := spawn run_auth_canary_server(mut app)
	server := <-app.ready
	server.wait_till_running() or { panic(err) }
	defer {
		server.shutdown(timeout: 5 * time.second) or {}
		canary_thread.wait()
	}
	marker := os.join_path(root, 'canary-ran')
	for method in ['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS'] {
		for headers in [[]string{}, ['Authorization: Bearer ${'d'.repeat(64)}'],
			['Authorization: Bearer ${'c'.repeat(63)}'],
			['Authorization: Bearer ${'c'.repeat(64)}', 'Origin: https://evil.example']] {
			response := auth_test_raw(port, auth_test_request(method, '/v1/canary', headers))
			status := auth_test_status(response)
			assert status.contains(' 401 ') || status.contains(' 403 '), '${method} ${headers} -> ${status}'
			assert !os.exists(marker), '${method} ${headers} executed the handler'
		}
		bad_host := auth_test_raw(port, '${method} /v1/canary HTTP/1.1\r\nHost: evil.example\r\nAuthorization: Bearer ${'c'.repeat(64)}\r\nConnection: close\r\n\r\n')
		assert auth_test_status(bad_host).contains(' 403 ')
		assert !os.exists(marker)
	}
	// Control: with the right token the same route does run, proving the
	// canary can observe execution.
	ok := auth_test_raw(port, auth_test_request('POST', '/v1/canary', [
		'Authorization: Bearer ${'c'.repeat(64)}',
		'Content-Length: 0',
	]))
	assert auth_test_status(ok).contains(' 200 ')
	assert os.exists(marker)
}

fn auth_test_goal_round_trip(port int, token string) {
	headers := ['Authorization: Bearer ${token}', 'Content-Type: application/json']
	fixture := new_auth_goal_repository_fixture() or {
		panic(err)
	}
	defer { os.rmdir_all(os.dir(fixture.root)) or {} }
	goal := GoalAdmission{
		schema_version:          1
		id:                      'http-goal'
		title:                   'HTTP goal'
		authorized_repositories: [GoalRepository{
			owner: 'veasel-labs'
			name:  'veasel'
			path:  fixture.root
		}]
		acceptance_criteria:     [GoalCriterion{
			id:           'test'
			description:  'Verify the manifest'
			verification: 'Review'
		}]
		deadline:                '2027-01-01T00:00:00Z'
		budget:                  GoalBudget{ max_attempts: 1, wall_seconds: 60, provider_turns: 1 }
		delivery_mode:           'report'
		tasks:                   [
			GoalTask{
				id:         'z-final'
				title:      'Final'
				repository: 'veasel-labs/veasel'
				base_sha:   fixture.commit
				paths:      ['docs']
				depends_on: ['a-start']
				recipe:     'feature'
				runner:     'local-v'
				verifier:   'review'
			},
			GoalTask{
				id:         'b-independent'
				title:      'Independent'
				repository: 'veasel-labs/veasel'
				base_sha:   fixture.commit
				paths:      ['docs']
				recipe:     'research'
				runner:     'local-v'
				verifier:   'review'
			},
			GoalTask{
				id:         'a-start'
				title:      'Start'
				repository: 'veasel-labs/veasel'
				base_sha:   fixture.commit
				paths:      ['docs']
				recipe:     'feature'
				runner:     'local-v'
				verifier:   'review'
			},
		]
	}
	body := json2.encode(goal, escape_unicode: true, time_as_unix: true)
	for expected in [' 201 ', ' 200 '] {
		request := auth_test_request('POST', '/v1/goals', [...headers, 'Content-Length: ${body.len}'])
		response := auth_test_raw(port, request + body)
		assert auth_test_status(response).contains(expected), auth_test_status(response)
	}
	changed := body.replace('HTTP goal', 'Changed goal')
	request := auth_test_request('POST', '/v1/goals', [...headers, 'Content-Length: ${changed.len}'])
	assert auth_test_status(auth_test_raw(port, request + changed)).contains(' 409 ')
	response := auth_test_raw(port, auth_test_request('GET', '/v1/goals/http-goal', headers))
	assert auth_test_status(response).contains(' 200 ')
	assert response.contains('HTTP goal')
	tasks_response := auth_test_raw(port, auth_test_request('GET', '/v1/goals/http-goal/tasks', headers))
	assert auth_test_status(tasks_response).contains(' 200 ')
	projection := json2.decode[GoalTasksProjection](tasks_response.all_after('\r\n\r\n')) or {
		panic(err)
	}
	assert projection.goal_id == 'http-goal'
	assert projection.status == 'admitted'
	assert projection.tasks.map(it.id) == ['b-independent', 'a-start', 'z-final']
	assert projection.tasks.map(it.status) == ['pending', 'pending', 'pending']
	assert projection.tasks.map(it.attempt_count) == [0, 0, 0]
	assert projection.tasks.map(it.attempts.len) == [0, 0, 0]
	assert projection.tasks.last().depends_on == ['a-start']
	assert auth_test_status(auth_test_raw(port, auth_test_request('GET', '/v1/goals/missing', headers))).contains(' 404 ')
	assert auth_test_status(auth_test_raw(port, auth_test_request('GET', '/v1/goals/missing/tasks', headers))).contains(' 404 ')

	mut large_tasks := []GoalTask{cap: 300}
	for i in 0 .. 300 {
		large_tasks << GoalTask{
			id:         'task-${i:03}'
			title:      'Task ${i}'
			repository: 'veasel-labs/veasel'
			base_sha:   'f'.repeat(40)
			paths:      ['src']
			recipe:     'feature'
			runner:     'local-v'
			verifier:   'review'
		}
	}
	large_goal := GoalAdmission{
		schema_version:          1
		id:                      'http-large-goal'
		title:                   'Large task graph'
		authorized_repositories: [GoalRepository{
			owner: 'veasel-labs'
			name:  'veasel'
			path:  '/work/veasel'
		}]
		acceptance_criteria:     [GoalCriterion{
			id:           'test'
			description:  'Verify projection'
			verification: 'Review'
		}]
		deadline:                '2027-01-01T00:00:00Z'
		budget:                  GoalBudget{
			max_attempts:   1
			wall_seconds:   60
			provider_turns: 1
		}
		delivery_mode:           'report'
		tasks:                   large_tasks
	}
	large_body := json2.encode(large_goal)
	large_post := auth_test_request('POST', '/v1/goals', [...headers,
		'Content-Length: ${large_body.len}'])
	assert auth_test_status(auth_test_raw(port, large_post + large_body)).contains(' 201 ')
	large_response := auth_test_raw(port, auth_test_request('GET', '/v1/goals/http-large-goal/tasks', headers))
	assert auth_test_status(large_response).contains(' 200 ')
	large_projection := json2.decode[GoalTasksProjection](large_response.all_after('\r\n\r\n')) or {
		panic(err)
	}
	assert large_projection.tasks.len == 300
	assert auth_test_status(auth_test_raw(port,
		auth_test_request('GET', '/v1/goals/missing/preflight', headers))).contains(' 404 ')
	status_before := run_workspace_git_command_output(fixture.root,
		['status', '--porcelain=v1', '-z', '--untracked-files=all'], 1024) or { panic(err) }
	worktrees_before := run_workspace_git_command_output(fixture.root, ['worktree', 'list',
		'--porcelain'],
		4096) or { panic(err) }
	preflight_request := auth_test_request('GET', '/v1/goals/http-goal/preflight', headers)
	preflight_response := auth_test_raw(port, preflight_request)
	assert auth_test_status(preflight_response).contains(' 200 '), auth_test_status(preflight_response)
	assert preflight_response.contains('"checkouts_validated":true')
	assert !preflight_response.contains('"ready"')
	assert !preflight_response.contains('execution_ready')
	assert preflight_response.contains('"tasks_checked":3')
	assert !preflight_response.contains(fixture.root)
	assert !preflight_response.contains(fixture.commit)
	assert !preflight_response.contains('github.com')
	assert (run_workspace_git_command_output(fixture.root,
		['status', '--porcelain=v1', '-z', '--untracked-files=all'], 1024) or { panic(err) }) == status_before
	assert (run_workspace_git_command_output(fixture.root, ['worktree', 'list', '--porcelain'],
		4096) or { panic(err) }) == worktrees_before

	// Capability rejection happens before the claim/worktree boundary. An
	// unknown runner must not consume an attempt or create a disposable
	// worktree, even when the repository checkout itself is valid.
	unknown_goal := GoalAdmission{
		...goal
		id:    'http-unknown-runner'
		title: 'HTTP unknown runner'
		tasks: goal.tasks.map(GoalTask{ ...it, runner: 'mystery-runner' })
	}
	unknown_body := json2.encode(unknown_goal, escape_unicode: true, time_as_unix: true)
	unknown_post := auth_test_request('POST', '/v1/goals', [...headers,
		'Content-Length: ${unknown_body.len}'])
	assert auth_test_status(auth_test_raw(port, unknown_post + unknown_body)).contains(' 201 ')
	unknown_before := run_workspace_git_command_output(fixture.root, ['worktree', 'list', '--porcelain'], 4096) or { panic(err) }
	start_body := '{"title":"Unknown runner attempt","prompt":"No provider call"}'
	start_response := auth_test_raw(port, auth_test_request('POST',
		'/v1/goals/http-unknown-runner/tasks/a-start/start', [...headers,
			'Content-Length: ${start_body.len}']) + start_body)
	assert auth_test_status(start_response).contains(' 409 '), auth_test_status(start_response)
	unknown_tasks_response := auth_test_raw(port,
		auth_test_request('GET', '/v1/goals/http-unknown-runner/tasks', headers))
	assert auth_test_status(unknown_tasks_response).contains(' 200 ')
	unknown_projection := json2.decode[GoalTasksProjection](unknown_tasks_response.all_after('\r\n\r\n')) or {
		panic(err)
	}
	assert unknown_projection.tasks.all(it.status == 'pending')
	assert unknown_projection.tasks.all(it.attempt_count == 0)
	assert (run_workspace_git_command_output(fixture.root, ['worktree', 'list', '--porcelain'], 4096) or { panic(err) }) == unknown_before
}

struct AuthGoalRepositoryFixture {
	root   string
	commit string
}

fn new_auth_goal_repository_fixture() !AuthGoalRepositoryFixture {
	parent := os.join_path(os.temp_dir(), 'veasel-auth-goal-${uuid.new_v4().str()}')
	root := os.join_path(parent, 'checkout')
	hooks := os.join_path(parent, 'empty-hooks')
	os.mkdir_all(os.join_path(root, 'docs'))!
	os.mkdir_all(hooks)!
	os.write_file(os.join_path(root, 'docs', 'README.md'), 'fixture')!
	_ = run_workspace_git_command_output(root, ['init', '--quiet', '-b', 'main'], 1024)!
	_ = run_workspace_git_command_output(root, ['config', 'user.name', 'Veasel Fixture'], 1024)!
	_ = run_workspace_git_command_output(root, ['config', 'user.email', 'fixture@example.invalid'], 1024)!
	_ = run_workspace_git_command_output(root, ['config', 'core.hooksPath', hooks], 1024)!
	_ = run_workspace_git_command_output(root, ['remote', 'add', 'origin',
		'https://github.com/veasel-labs/veasel.git'], 1024)!
	_ = run_workspace_git_command_output(root, ['add', '--', 'docs/README.md'], 1024)!
	_ = run_workspace_git_command_output(root, ['-c', 'commit.gpgsign=false', 'commit', '--no-gpg-sign',
		'-m', 'fixture'], 1024)!
	commit := run_workspace_git_command_output(root, ['rev-parse', '--verify', 'HEAD'], 1024)!
	return AuthGoalRepositoryFixture{
		root:   os.real_path(root)
		commit: commit.trim_space()
	}
}
