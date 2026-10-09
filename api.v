module main

import json2
import strconv
import time
import veb
import veb.sse

const version = '0.1.0'

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

pub struct App {
pub:
	store &Store
}

@['/v1/health'; get]
pub fn (app &App) health(mut ctx Context) veb.Result {
	return ctx.json(Health{
		healthy: true
		version: version
	})
}

@['/v1/capabilities'; get]
pub fn (app &App) capabilities(mut ctx Context) veb.Result {
	return ctx.json(Capabilities{
		api_version: 'v1'
		features:    ['sessions.create', 'sessions.list', 'sessions.get', 'events.sse', 'events.replay']
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
	if input.directory.trim_space().len == 0 || input.directory.len > 4096 {
		return json_request_error(mut ctx, 'Directory must contain 1 to 4096 characters')
	}
	session := app.store.create_session(SessionInput{
		title:     input.title.trim_space()
		directory: input.directory.trim_space()
	}) or {
		eprintln('veasel: create session failed: ${err}')
		return json_server_error(mut ctx, 'Unable to create session')
	}
	ctx.res.set_status(.created)
	return ctx.json(session)
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
