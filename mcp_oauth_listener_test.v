module main

import net.http
import time

fn test_mcp_oauth_loopback_listener_captures_callback_query() {
	mut listener := start_mcp_oauth_loopback_listener('/oauth/cb', 5 * time.second) or {
		panic(err)
	}
	assert listener.redirect_uri().starts_with('http://127.0.0.1:')
	assert listener.redirect_uri().ends_with('/oauth/cb')
	uri := listener.redirect_uri()
	spawn fn [uri] () {
		time.sleep(50 * time.millisecond)
		http.get('${uri}?code=loopback-code&state=loopback-state') or {}
	}()
	callback := listener.wait() or { panic(err) }
	assert callback.code == 'loopback-code'
	assert callback.state == 'loopback-state'
	assert callback.error.len == 0
}

fn test_mcp_oauth_loopback_listener_surfaces_authorization_error() {
	mut listener := start_mcp_oauth_loopback_listener('/callback', 5 * time.second) or {
		panic(err)
	}
	uri := listener.redirect_uri()
	spawn fn [uri] () {
		time.sleep(50 * time.millisecond)
		http.get('${uri}?error=access_denied&state=err-state&error_description=nope') or {}
	}()
	callback := listener.wait() or { panic(err) }
	assert callback.state == 'err-state'
	assert callback.error == 'access_denied'
	assert callback.code.len == 0
}

fn test_mcp_oauth_loopback_listener_rejects_wrong_path() {
	mut listener := start_mcp_oauth_loopback_listener('/callback', 800 * time.millisecond) or {
		panic(err)
	}
	uri := listener.redirect_uri().replace('/callback', '/other')
	spawn fn [uri] () {
		time.sleep(50 * time.millisecond)
		http.get('${uri}?code=x&state=y') or {}
	}()
	if _ := listener.wait() {
		assert false
	} else {
		assert err.msg().contains('timed out') || err.msg().contains('invalid')
	}
}
