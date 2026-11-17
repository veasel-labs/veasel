module main

import crypto.rand
import crypto.sha256
import crypto.subtle
import net.http
import os
import sync
import time
import veb

// Caller authentication for the loopback API. Design, alternatives, and
// limits: docs/security/backend-caller-auth.md.

const api_token_file_name = 'api-token'
const api_token_env = 'VEASEL_API_TOKEN'
const api_token_hex_len = 64
const api_token_env_min_len = 32
const api_token_env_max_len = 512
const api_token_stale_temp_seconds = 60

// Process-wide verifier. veb builds a fresh Context per request with no
// access to the App, so the digest lives behind this pointer instead.
// Only a SHA-256 digest of the token is kept in memory.
@[heap]
struct APIAuthState {
mut:
	mu          sync.RwMutex
	digest      []u8
	ready       bool
	token_path  string
	env_managed bool
}

const api_auth = &APIAuthState{}

fn token_digest(token string) []u8 {
	return sha256.sum256(token.bytes())
}

fn (mut s APIAuthState) configure(token string, token_path string, env_managed bool) {
	s.mu.lock()
	s.digest = token_digest(token)
	s.ready = true
	s.token_path = token_path
	s.env_managed = env_managed
	s.mu.unlock()
}

fn (mut s APIAuthState) reset() {
	s.mu.lock()
	s.digest = []u8{}
	s.ready = false
	s.token_path = ''
	s.env_managed = false
	s.mu.unlock()
}

// Fails closed: an unconfigured verifier accepts nothing. The candidate is
// hashed first so the comparison is constant-time and length-independent.
fn (mut s APIAuthState) verify(candidate string) bool {
	if candidate.len == 0 || candidate.len > api_token_env_max_len {
		return false
	}
	candidate_digest := token_digest(candidate)
	s.mu.rlock()
	defer {
		s.mu.runlock()
	}
	if !s.ready {
		return false
	}
	return subtle.constant_time_compare(s.digest, candidate_digest) == 1
}

fn api_auth_state() &APIAuthState {
	return unsafe { api_auth }
}

fn generate_api_token() !string {
	bytes := rand.bytes(32)!
	return bytes.hex()
}

fn is_valid_generated_token(token string) bool {
	if token.len != api_token_hex_len {
		return false
	}
	for c in token {
		if !((c >= `0` && c <= `9`) || (c >= `a` && c <= `f`)) {
			return false
		}
	}
	return true
}

// Operator-supplied tokens must be long enough to resist guessing and safe
// to place in an HTTP header.
fn is_valid_env_token(token string) bool {
	if token.len < api_token_env_min_len || token.len > api_token_env_max_len {
		return false
	}
	for c in token {
		if c <= ` ` || c >= 127 {
			return false
		}
	}
	return true
}

fn api_token_path(data_dir string) string {
	return os.join_path(data_dir, api_token_file_name)
}

fn remove_stale_token_temporaries(data_dir string) {
	entries := os.ls(data_dir) or { return }
	now := time.now().unix()
	for entry in entries {
		if !entry.starts_with('${api_token_file_name}.tmp-') {
			continue
		}
		path := os.join_path(data_dir, entry)
		st := os.lstat(path) or { continue }
		if now - i64(st.mtime) > api_token_stale_temp_seconds {
			os.rm(path) or {}
		}
	}
}

// Writes `token` to a unique 0600 temporary file and returns its path.
fn write_token_temporary(data_dir string, token string) !string {
	suffix := rand.bytes(6)!.hex()
	tmp := os.join_path(data_dir, '${api_token_file_name}.tmp-${os.getpid()}-${suffix}')
	create_private_file_exclusive(tmp, token + '\n')!
	return tmp
}

fn read_token_file(path string) !string {
	verify_private_file(path)!
	token := os.read_file(path)!.trim_space()
	if !is_valid_generated_token(token) {
		return error('${path} does not contain a valid token')
	}
	return token
}

// Returns the token stored in the data directory, creating it atomically on
// first use. Creation writes a complete 0600 temporary file and links it
// into place, so a crash can never leave a partial token and two
// concurrently starting servers converge on one value.
fn load_or_create_api_token(data_dir string) !string {
	ensure_private_directory(data_dir)!
	remove_stale_token_temporaries(data_dir)
	path := api_token_path(data_dir)
	for _ in 0 .. 5 {
		if os.exists(path) || os.is_link(path) {
			return read_token_file(path) or {
				// Wrong permissions or a foreign owner is never repaired
				// silently: fail closed and tell the operator.
				if os.is_link(path) || !os.exists(path) {
					return err
				}
				verify_private_file(path)!
				// Secure but malformed (hand-edited or truncated by a
				// full disk): replace it atomically.
				return replace_api_token(data_dir)
			}
		}
		token := generate_api_token()!
		tmp := write_token_temporary(data_dir, token)!
		os.link(tmp, path) or {
			os.rm(tmp) or {}
			if os.exists(path) {
				continue
			}
			$if windows {
				// NTFS hard links can be unavailable on some volumes.
				write_token_via_rename(data_dir, token) or { return err }
				return token
			}
			return error('unable to install ${path}: ${err}')
		}
		os.rm(tmp) or {}
		return token
	}
	return error('unable to create ${path}')
}

fn write_token_via_rename(data_dir string, token string) ! {
	tmp := write_token_temporary(data_dir, token)!
	os.rename(tmp, api_token_path(data_dir)) or {
		os.rm(tmp) or {}
		return err
	}
}

// Atomically replaces the token file with a fresh token (POSIX rename
// overwrites in one step, so readers see the old or the new value, never a
// partial one).
fn replace_api_token(data_dir string) !string {
	ensure_private_directory(data_dir)!
	token := generate_api_token()!
	write_token_via_rename(data_dir, token)!
	return token
}

// Configures the process-wide verifier. VEASEL_API_TOKEN wins and is never
// written to disk; otherwise the data-directory file is used (and created).
fn init_api_auth(data_dir string) ! {
	mut state := api_auth_state()
	if env_token := os.getenv_opt(api_token_env) {
		if env_token.len > 0 {
			if !is_valid_env_token(env_token) {
				return error('${api_token_env} must be ${api_token_env_min_len}-${api_token_env_max_len} printable ASCII characters without spaces')
			}
			state.configure(env_token, '', true)
			return
		}
	}
	token := load_or_create_api_token(data_dir)!
	state.configure(token, api_token_path(data_dir), false)
}

// Rotates the token file and the live verifier together. Clients holding
// the previous value are rejected from this point on.
fn rotate_api_token() ! {
	mut state := api_auth_state()
	state.mu.rlock()
	managed := state.env_managed
	path := state.token_path
	state.mu.runlock()
	if managed || path.len == 0 {
		return error('the token is managed by ${api_token_env}; change that variable and restart the server')
	}
	data_dir := os.dir(path)
	token := replace_api_token(data_dir)!
	state.configure(token, path, false)
}

// Client-side discovery: VEASEL_API_TOKEN first, then the data-directory
// file (which must pass the same permission checks the server enforces).
fn discover_api_token(data_dir string) ?string {
	if env_token := os.getenv_opt(api_token_env) {
		if env_token.len > 0 {
			return env_token
		}
	}
	token := read_token_file(api_token_path(data_dir)) or { return none }
	return token
}

fn api_auth_header(data_dir string) ?string {
	token := discover_api_token(data_dir) or { return none }
	return 'Bearer ${token}'
}

// Extracts the bearer credential. Exactly one Authorization header with the
// `Bearer` scheme is accepted; query-string or cookie credentials are
// deliberately ignored (they leak into logs, history, and Referer).
fn bearer_token_from_request(header http.Header) string {
	values := header.values(.authorization)
	if values.len != 1 {
		return ''
	}
	value := values[0]
	if value.len <= 7 || value[..7].to_lower() != 'bearer ' {
		return ''
	}
	return value[7..]
}

fn request_path(raw_url string) string {
	return raw_url.all_before('?').all_before('#')
}

// Only a bare GET of the exact health path is liveness-exempt. Any other
// spelling (trailing slash, case, encoding, absolute-form, other methods)
// falls through to authentication.
fn is_unauthenticated_liveness_request(method http.Method, raw_url string) bool {
	return method == .get && request_path(raw_url) == '/v1/health'
}

fn reject_unauthenticated(mut ctx Context) {
	ctx.res.set_status(.unauthorized)
	ctx.res.header.set_custom('WWW-Authenticate', 'Bearer realm="veasel"') or {}
	ctx.res.header.set_custom('Cache-Control', 'no-store') or {}
	ctx.json(APIError{
		error: 'authentication required: send "Authorization: Bearer <token>". The token is the contents of the api-token file in the Veasel data directory (\$VEASEL_DATA_DIR, default ~/.local/share/veasel) or the ${api_token_env} environment variable.'
	})
}

@['/v1/auth/rotate'; post]
pub fn (app &App) rotate_auth_token(mut ctx Context) veb.Result {
	rotate_api_token() or {
		ctx.res.set_status(.conflict)
		return ctx.json(APIError{
			error: err.msg()
		})
	}
	return ctx.json(AuthRotation{
		rotated: true
	})
}

struct AuthRotation {
pub:
	rotated bool
}
