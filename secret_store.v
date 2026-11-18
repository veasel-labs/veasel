module main

import crypto.sha256
import encoding.hex
import os
import time

// OS credential storage for provider API keys (issue #690, epic #689).
//
// Design (see docs/security/threat-model.md, flow 2):
//   * Linux  : libsecret via `secret-tool`; the secret travels on stdin only.
//   * macOS  : `/usr/bin/security -i` reads its command script from stdin, so
//              the (hex-encoded) secret never appears in any process argv.
//   * Windows: Credential Manager through CredWriteW/CredReadW (C interop,
//              secret_store_native_windows.c.v); no process is spawned.
// A secret is never passed as a command-line argument on any platform.

const secret_service_name = 'veasel'
const secret_command_timeout_ms = 20_000
const secret_store_file_hint = 'set VEASEL_SECRET_STORE=file to keep provider keys in the owner-only settings file instead (plaintext at rest)'

struct SecretCommandResult {
pub:
	code   int
	stdout string
	stderr string
}

type SecretRunnerFn = fn (exe string, args []string, stdin string) !SecretCommandResult

// SecretBackend is the narrow interface between model settings and an OS
// credential store. `get` returns '' when no entry exists and an error when
// the store itself is unavailable or locked.
interface SecretBackend {
mut:
	get(account string) !string
	set(account string, secret string) !
	delete(account string) !
}

// keychain_error builds the actionable, secret-free error shown to users.
fn keychain_error(detail string) IError {
	mut clean := detail.trim_space()
	if clean.contains('\n') {
		clean = clean.all_before('\n')
	}
	if clean.len > 200 {
		clean = clean[..200]
	}
	clean = clean.replace('\r', ' ')
	return error('OS keychain is unavailable (${clean}); unlock it or start a Secret Service provider, or ${secret_store_file_hint}')
}

fn with_keychain_hint(message string) string {
	if message.contains('VEASEL_SECRET_STORE=file') {
		return message
	}
	return keychain_error(message).msg()
}

// parse_secret_store_mode maps VEASEL_SECRET_STORE to keychain|file|invalid.
// Unset means keychain; anything unrecognised is refused rather than guessed.
fn parse_secret_store_mode(raw string) string {
	value := raw.trim_space().to_lower()
	return match value {
		'', 'keychain' { 'keychain' }
		'file' { 'file' }
		else { 'invalid' }
	}
}

// secret_account_scope isolates entries per settings directory, so two
// VEASEL_DATA_DIRs on one machine never overwrite each other's keys.
fn secret_account_scope(settings_path string) string {
	dir := os.dir(settings_path)
	resolved := os.real_path(dir)
	return sha256.hexhash(resolved)[..16]
}

fn model_secret_account(scope string, provider string) string {
	return 'model-api-key/${scope}/${provider}'
}

fn secret_account_is_safe(account string) bool {
	if account.len == 0 || account.len > 200 {
		return false
	}
	for ch in account {
		if !(ch.is_letter() || ch.is_digit() || ch == `/` || ch == `-` || ch == `_` || ch == `.`) {
			return false
		}
	}
	return true
}

fn default_secret_runner(exe string, args []string, stdin string) !SecretCommandResult {
	resolved := if exe.contains('/') {
		exe
	} else {
		os.find_abs_path_of_executable(exe) or {
			return error('${exe} is not installed')
		}
	}
	return run_secret_command(resolved, args, stdin, secret_command_timeout_ms)
}

// run_secret_command execs `exe` with a literal argument array (no shell),
// writes `stdin` then closes it, and collects output with a hard deadline so
// a locked keyring waiting on an unlock prompt cannot hang the server.
fn run_secret_command(exe string, args []string, stdin string, timeout_ms int) !SecretCommandResult {
	$if windows {
		return error('external secret helpers are not used on Windows')
	} $else {
		mut p := os.new_process(exe)
		p.set_args(args)
		p.set_redirect_stdio()
		p.run()
		if p.status != .running {
			p.close()
			return error('could not start ${os.file_name(exe)}')
		}
		if stdin.len > 0 {
			p.stdin_write(stdin)
		}
		os.fd_close(p.stdio_fd[0])
		deadline := time.now().unix_milli() + timeout_ms
		mut out := ''
		mut err_out := ''
		for p.is_alive() {
			out += p.stdout_read()
			err_out += p.stderr_read()
			if time.now().unix_milli() > deadline {
				p.signal_kill()
				p.wait()
				p.close()
				return error('${os.file_name(exe)} timed out (the keyring may be waiting for an unlock)')
			}
			time.sleep(10 * time.millisecond)
		}
		p.wait()
		out += p.stdout_slurp()
		err_out += p.stderr_slurp()
		code := p.code
		p.close()
		return SecretCommandResult{
			code:   code
			stdout: out
			stderr: err_out
		}
	}
}

// ---- Linux: Secret Service via secret-tool ----------------------------

struct SecretToolBackend {
mut:
	runner SecretRunnerFn = default_secret_runner
}

fn (mut b SecretToolBackend) get(account string) !string {
	if !secret_account_is_safe(account) {
		return error('invalid secret account')
	}
	res := b.runner('secret-tool', ['lookup', 'service', secret_service_name, 'account', account],
		'') or { return keychain_error(err.msg()) }
	if res.code == 0 {
		return res.stdout
	}
	if res.code == 1 && res.stderr.trim_space() == '' {
		return ''
	}
	return keychain_error(res.stderr)
}

fn (mut b SecretToolBackend) set(account string, secret string) ! {
	if !secret_account_is_safe(account) {
		return error('invalid secret account')
	}
	res := b.runner('secret-tool', ['store', '--label=Veasel provider API key', 'service',
		secret_service_name, 'account', account],
		secret) or { return keychain_error(err.msg()) }
	if res.code != 0 {
		return keychain_error(res.stderr)
	}
}

fn (mut b SecretToolBackend) delete(account string) ! {
	if !secret_account_is_safe(account) {
		return error('invalid secret account')
	}
	res := b.runner('secret-tool', ['clear', 'service', secret_service_name, 'account', account],
		'') or { return keychain_error(err.msg()) }
	if res.code != 0 && !(res.code == 1 && res.stderr.trim_space() == '') {
		return keychain_error(res.stderr)
	}
}

// ---- macOS: /usr/bin/security with the command script on stdin --------

struct MacKeychainBackend {
mut:
	runner SecretRunnerFn = default_secret_runner
}

const mac_security_tool = '/usr/bin/security'
const mac_item_not_found = 44

fn (mut b MacKeychainBackend) get(account string) !string {
	if !secret_account_is_safe(account) {
		return error('invalid secret account')
	}
	res := b.runner(mac_security_tool, ['find-generic-password', '-s', secret_service_name, '-a',
		account, '-w'],
		'') or { return keychain_error(err.msg()) }
	if res.code == mac_item_not_found {
		return ''
	}
	if res.code != 0 {
		return keychain_error(res.stderr)
	}
	decoded := hex.decode(res.stdout.trim_space()) or {
		return keychain_error('stored value is not in the expected format')
	}
	return decoded.bytestr()
}

fn (mut b MacKeychainBackend) set(account string, secret string) ! {
	if !secret_account_is_safe(account) {
		return error('invalid secret account')
	}
	// Hex keeps the script free of quoting hazards and non-ASCII bytes.
	script := 'add-generic-password -U -s ${secret_service_name} -a ${account} -w ${hex.encode(secret.bytes())}\n'
	res := b.runner(mac_security_tool, ['-i'], script) or { return keychain_error(err.msg()) }
	if res.code != 0 {
		return keychain_error(res.stderr)
	}
	// `security -i` can report command errors without a failing exit status;
	// callers always read the value back before trusting a write.
}

fn (mut b MacKeychainBackend) delete(account string) ! {
	if !secret_account_is_safe(account) {
		return error('invalid secret account')
	}
	res := b.runner(mac_security_tool, ['delete-generic-password', '-s', secret_service_name, '-a',
		account],
		'') or { return keychain_error(err.msg()) }
	if res.code != 0 && res.code != mac_item_not_found {
		return keychain_error(res.stderr)
	}
}

// UnavailableSecretBackend fails every call closed with a fixed reason.
struct UnavailableSecretBackend {
	reason string
}

fn (mut b UnavailableSecretBackend) get(account string) !string {
	return keychain_error(b.reason)
}

fn (mut b UnavailableSecretBackend) set(account string, secret string) ! {
	return keychain_error(b.reason)
}

fn (mut b UnavailableSecretBackend) delete(account string) ! {
	return keychain_error(b.reason)
}
