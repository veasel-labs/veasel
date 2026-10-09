module main

import json2
import os
import strconv
import sync
import time
import veb
import veb.sse

const max_provider_concurrency = 4
const session_turn_lock_stripes = 64

struct Health {
pub:
	healthy bool
	version string
}

struct Capabilities {
pub:
	api_version string
	features    []string
}

struct APIError {
pub:
	error string
}

struct ChatMessageInput {
pub:
	content string
}

struct ChatExchange {
pub:
	messages []ChatTurn
	provider string
	model    string
}

fn json_request_error(mut ctx Context, message string) veb.Result {
	ctx.res.set_status(.bad_request)
	return ctx.json(APIError{
		error: message
	})
}

fn json_server_error(mut ctx Context, message string) veb.Result {
	ctx.res.set_status(.internal_server_error)
	return ctx.json(APIError{
		error: message
	})
}

pub struct Context {
	veb.Context
}

pub fn (mut ctx Context) before_request() {
	host := ctx.req.header.get_custom('Host', exact: false) or { '' }
	if !is_loopback_host(host) {
		ctx.res.set_status(.forbidden)
		ctx.text('The API only accepts loopback Host values')
		return
	}
	origin := ctx.req.header.get_custom('Origin', exact: false) or { return }
	if !is_loopback_origin(origin) {
		ctx.res.set_status(.forbidden)
		ctx.text('The API only accepts loopback browser origins')
	}
}

pub struct App {
	session_turn_locks []&sync.Mutex
	provider_slots     &sync.Semaphore
pub:
	store &Store
}

fn new_app(store &Store) &App {
	mut session_turn_locks := []&sync.Mutex{cap: session_turn_lock_stripes}
	for _ in 0 .. session_turn_lock_stripes {
		session_turn_locks << sync.new_mutex()
	}
	return &App{
		store:              store
		session_turn_locks: session_turn_locks
		provider_slots:     sync.new_semaphore_init(max_provider_concurrency)
	}
}

fn (app &App) session_turn_lock(id string) &sync.Mutex {
	index := session_turn_lock_index(id)
	return app.session_turn_locks[index]
}

fn session_turn_lock_index(id string) int {
	return id.hash() % session_turn_lock_stripes
}

fn (app &App) complete_with_provider_limit(input CompletionInput) !CompletionOutput {
	mut slots := app.provider_slots
	slots.wait()
	defer {
		slots.post()
	}
	return complete(input)
}

fn (mut app App) close() {
	for index in 0 .. app.session_turn_locks.len {
		mut lock_ref := app.session_turn_locks[index]
		lock_ref.destroy()
	}
	mut slots := app.provider_slots
	slots.destroy()
}

@['/v1/health'; get]
pub fn (app &App) health(mut ctx Context) veb.Result {
	return ctx.json(Health{
		healthy: true
		version: product_version
	})
}

@['/v1/capabilities'; get]
pub fn (app &App) capabilities(mut ctx Context) veb.Result {
	mut features := ['sessions.create', 'sessions.list', 'sessions.get', 'events.sse', 'events.replay']
	if configured_model() != none {
		features << 'chat.complete'
	}
	return ctx.json(Capabilities{
		api_version: 'v1'
		features:    features
	})
}

@['/v1/chat/completions'; post]
pub fn (app &App) complete_chat(mut ctx Context) veb.Result {
	if ctx.req.data.len > max_chat_input_bytes + 8192 {
		return json_request_error(mut ctx, 'Request body exceeds the size limit')
	}
	input := json2.decode[CompletionInput](ctx.req.data) or {
		return json_request_error(mut ctx, 'Expected JSON with a messages array')
	}
	validate_messages(input.messages) or {
		return json_request_error(mut ctx, err.msg())
	}
	if configured_model() == none {
		ctx.res.set_status(.service_unavailable)
		return ctx.json(APIError{
			error: 'Configure VEASEL_MODEL_PROVIDER, VEASEL_MODEL, and the provider API key to use chat completions'
		})
	}
	output := app.complete_with_provider_limit(input) or {
		eprintln('veasel: model provider request failed (${err.msg()})')
		ctx.res.set_status(.bad_gateway)
		return ctx.json(APIError{
			error: 'Model provider request failed'
		})
	}
	return ctx.json(output)
}

@['/v1/sessions/:id/messages'; get]
pub fn (app &App) get_session_messages(mut ctx Context, id string) veb.Result {
	_ := app.store.get_session(id) or {
		ctx.res.set_status(.not_found)
		return ctx.json(APIError{
			error: 'session not found'
		})
	}
	messages := app.store.messages_for_session(id, 100) or {
		return json_server_error(mut ctx, 'Unable to read session messages')
	}
	return ctx.json(messages)
}

@['/v1/sessions/:id/messages'; post]
pub fn (app &App) send_session_message(mut ctx Context, id string) veb.Result {
	if ctx.req.data.len > max_chat_input_bytes + 1024 {
		return json_request_error(mut ctx, 'Request body exceeds the size limit')
	}
	input := json2.decode[ChatMessageInput](ctx.req.data) or {
		return json_request_error(mut ctx, 'Expected JSON with a content field')
	}
	user_message := ChatMessage{
		role:    'user'
		content: input.content
	}
	validate_messages([user_message]) or {
		return json_request_error(mut ctx, err.msg())
	}
	_ := app.store.get_session(id) or {
		ctx.res.set_status(.not_found)
		return ctx.json(APIError{
			error: 'session not found'
		})
	}
	if configured_model() == none {
		ctx.res.set_status(.service_unavailable)
		return ctx.json(APIError{
			error: 'Configure VEASEL_MODEL_PROVIDER, VEASEL_MODEL, and the provider API key to use chat completions'
		})
	}
	mut turn_lock := app.session_turn_lock(id)
	turn_lock.lock()
	defer {
		turn_lock.unlock()
	}
	mut messages := [ChatMessage{
		role:    'system'
		content: 'You are Veasel Code, a coding assistant. You can explain code and help plan changes, but this version cannot inspect or edit repository files or execute commands. Never claim that you performed actions.'
	}]
	history := app.store.messages_for_session(id, max_chat_messages - 2) or {
		return json_server_error(mut ctx, 'Unable to read session messages')
	}
	for turn in history {
		messages << ChatMessage{
			role:    turn.role
			content: turn.content
		}
	}
	messages << user_message
	output := app.complete_with_provider_limit(CompletionInput{
		messages: messages
	}) or {
		eprintln('veasel: session completion failed (${err.msg()})')
		ctx.res.set_status(.bad_gateway)
		return ctx.json(APIError{
			error: 'Model provider request failed'
		})
	}
	persisted := app.store.append_exchange(id, input.content, output.content) or {
		if err.msg() == 'session not found' {
			ctx.res.set_status(.not_found)
			return ctx.json(APIError{
				error: 'session not found'
			})
		}
		return json_server_error(mut ctx, 'Unable to persist session messages')
	}
	return ctx.json(ChatExchange{
		messages: persisted
		provider: output.provider
		model:    output.model
	})
}

@['/v1/sessions'; get]
pub fn (app &App) list_sessions(mut ctx Context) veb.Result {
	sessions := app.store.list_sessions() or {
		return json_server_error(mut ctx, 'Unable to list sessions')
	}
	return ctx.json(sessions)
}

@['/v1/sessions'; post]
pub fn (app &App) create_session(mut ctx Context) veb.Result {
	input := json2.decode[SessionInput](ctx.req.data) or {
		return json_request_error(mut ctx, 'Expected JSON with title and directory')
	}
	if input.title.trim_space().len == 0 || input.title.len > 200 {
		return json_request_error(mut ctx, 'Title must contain 1 to 200 characters')
	}
	if input.directory.len == 0 || input.directory.len > 4096 {
		return json_request_error(mut ctx, 'Directory must contain 1 to 4096 characters')
	}
	directory := canonical_workspace_root(input.directory) or {
		return json_request_error(mut ctx, 'Directory must resolve to an existing workspace directory')
	}
	session := app.store.create_session(SessionInput{
		title:     input.title.trim_space()
		directory: directory
	}) or {
		eprintln('veasel: create session failed: ${err}')
		return json_server_error(mut ctx, 'Unable to create session')
	}
	ctx.res.set_status(.created)
	return ctx.json(session)
}

fn canonical_workspace_root(path string) !string {
	if path.len == 0 || path.len > 4096 {
		return error('invalid workspace directory')
	}
	canonical := os.real_path(path)
	if !os.is_abs_path(canonical) || !os.is_dir(canonical) {
		return error('workspace directory does not exist')
	}
	return canonical
}

@['/v1/sessions/:id'; get]
pub fn (app &App) get_session(mut ctx Context, id string) veb.Result {
	session := app.store.get_session(id) or {
		ctx.res.set_status(.not_found)
		return ctx.json(APIError{
			error: 'session not found'
		})
	}
	return ctx.json(session)
}

@['/v1/events'; get]
pub fn (app &App) event_stream(mut ctx Context) veb.Result {
	last_id := ctx.req.header.get_custom('Last-Event-ID', exact: false) or { '0' }
	after := strconv.atoi(last_id) or {
		return json_request_error(mut ctx, 'Last-Event-ID must be a non-negative integer')
	}
	if after < 0 {
		return json_request_error(mut ctx, 'Last-Event-ID must be a non-negative integer')
	}
	ctx.takeover_conn()
	spawn stream_events(mut ctx, app.store, after)
	return veb.no_result()
}

fn stream_events(mut ctx Context, store &Store, start_after int) {
	mut stream := sse.start_connection(mut ctx.Context)
	mut cursor := start_after
	mut last_heartbeat := time.now()
	for {
		events := store.events_after(cursor) or {
			stream.send_message(event: 'error', data: 'event store unavailable') or {}
			break
		}
		for event in events {
			payload := json2.encode[Event](event)
			stream.send_message(id: event.id.str(), event: event.type, data: payload) or {
				stream.close()
				return
			}
			cursor = event.id
		}
		if time.since(last_heartbeat) >= 15 * time.second {
			stream.send_message(event: 'heartbeat', data: '{}') or {
				stream.close()
				return
			}
			last_heartbeat = time.now()
		}
		time.sleep(250 * time.millisecond)
	}
	stream.close()
}
