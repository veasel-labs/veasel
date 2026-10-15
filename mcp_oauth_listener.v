module main

import net.http
import net.urllib
import sync
import time

const mcp_oauth_loopback_default_path = '/callback'
const mcp_oauth_loopback_success_body = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Veasel OAuth</title></head><body><p>Authorization complete. You can close this window and return to Veasel.</p></body></html>'
const mcp_oauth_loopback_error_body = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Veasel OAuth</title></head><body><p>Authorization failed or the callback was invalid. You can close this window.</p></body></html>'

@[heap]
struct MCPOAuthLoopbackCapture {
mut:
	mu        sync.Mutex
	path      string
	done      chan int
	result    MCPOAuthCallbackResult
	finished  bool
	had_error bool
}

fn (mut capture MCPOAuthLoopbackCapture) handle(request http.Request) http.Response {
	mut response := http.Response{
		header: http.new_header_from_map({
			http.CommonHeader.content_type:  'text/html; charset=utf-8'
			http.CommonHeader.cache_control: 'no-store'
		})
	}
	if request.method != .get && request.method != .head {
		response.set_status(.method_not_allowed)
		response.body = mcp_oauth_loopback_error_body
		return response
	}
	parsed := urllib.parse(request.url) or {
		response.set_status(.bad_request)
		response.body = mcp_oauth_loopback_error_body
		return response
	}
	request_path := if parsed.path.len > 0 { parsed.path } else { '/' }
	if request_path != capture.path {
		response.set_status(.not_found)
		response.body = mcp_oauth_loopback_error_body
		return response
	}
	query := if parsed.raw_query.len > 0 {
		parsed.raw_query
	} else if request.url.contains('?') {
		request.url.all_after('?')
	} else {
		''
	}
	callback := parse_mcp_oauth_callback_query(query) or {
		response.set_status(.bad_request)
		response.body = mcp_oauth_loopback_error_body
		capture.finish_error()
		return response
	}
	capture.finish_ok(callback)
	response.set_status(.ok)
	if request.method == .get {
		response.body = mcp_oauth_loopback_success_body
	}
	return response
}

fn (mut capture MCPOAuthLoopbackCapture) finish_ok(callback MCPOAuthCallbackResult) {
	capture.mu.lock()
	defer {
		capture.mu.unlock()
	}
	if capture.finished {
		return
	}
	capture.result = callback
	capture.finished = true
	capture.had_error = false
	capture.done <- 1
}

fn (mut capture MCPOAuthLoopbackCapture) finish_error() {
	capture.mu.lock()
	defer {
		capture.mu.unlock()
	}
	if capture.finished {
		return
	}
	capture.finished = true
	capture.had_error = true
	capture.done <- 1
}

@[heap]
pub struct MCPOAuthLoopbackListener {
mut:
	server       &http.Server
	capture      &MCPOAuthLoopbackCapture
	redirect_uri string
	timeout      time.Duration
	closed       bool
}

fn start_mcp_oauth_loopback_listener(callback_path string, timeout time.Duration) !&MCPOAuthLoopbackListener {
	path := if callback_path.trim_space().len > 0 {
		callback_path.trim_space()
	} else {
		mcp_oauth_loopback_default_path
	}
	if !path.starts_with('/') || path.contains('\\') || path.contains('?') || path.contains('#') {
		return error('OAuth loopback callback path is invalid')
	}
	wait_timeout := if timeout > 0 { timeout } else { 3 * time.minute }
	mut capture := &MCPOAuthLoopbackCapture{
		path: path
		done: chan int{cap: 1}
	}
	mut server := &http.Server{
		accept_timeout:       250 * time.millisecond
		handler:              capture
		addr:                 '127.0.0.1:0'
		show_startup_message: false
		worker_num:           1
	}
	spawn server.listen_and_serve()
	server.wait_till_running() or {
		server.stop()
		return error('OAuth loopback listener failed to start')
	}
	redirect_uri := validate_mcp_oauth_loopback_redirect_uri('http://${server.addr}${path}')!
	return &MCPOAuthLoopbackListener{
		server:       server
		capture:      capture
		redirect_uri: redirect_uri
		timeout:      wait_timeout
	}
}

fn (listener &MCPOAuthLoopbackListener) redirect_uri() string {
	return listener.redirect_uri
}

fn (mut listener MCPOAuthLoopbackListener) wait() !MCPOAuthCallbackResult {
	if listener.closed {
		return error('OAuth loopback listener is closed')
	}
	select {
		_ := <-listener.capture.done {
			listener.capture.mu.lock()
			result := listener.capture.result
			had_error := listener.capture.had_error
			listener.capture.mu.unlock()
			listener.close()
			if had_error {
				return error('OAuth loopback callback was invalid')
			}
			return result
		}
		listener.timeout {
			listener.close()
			return error('OAuth loopback callback timed out')
		}
	}
	return error('OAuth loopback callback timed out')
}

fn (mut listener MCPOAuthLoopbackListener) close() {
	if listener.closed {
		return
	}
	listener.closed = true
	listener.server.stop()
}
