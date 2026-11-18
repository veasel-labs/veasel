module main

import crypto.rand
import os

// Windows has no POSIX mode bits, so the token is protected by an explicit
// ACL. The data DIRECTORY is restricted first (inheritance removed, only the
// current user granted) so a newly created token file inherits a private ACL
// from its first instant; the file is then restricted again explicitly.
// Startup and every client read verify the DACL (SIDs from `icacls /save`,
// allowlist in api_auth_acl.v: current user, SYSTEM, Administrators) and
// refuse (fail closed) when any other principal holds an entry. Arguments are always passed as arrays (no shell, no environment
// interpolation). See docs/security/backend-caller-auth.md.

struct WindowsPrincipal {
	name string // DOMAIN\user as printed by icacls
	sid  string // S-1-5-21-...
}

// `whoami /user /fo csv /nh` prints: "DOMAIN\user","S-1-5-21-..."
fn current_windows_principal() !WindowsPrincipal {
	result := os.exec(['whoami', '/user', '/fo', 'csv', '/nh'])
	if result.exit_code != 0 {
		return error('whoami could not identify the current user')
	}
	line := result.output.trim_space().all_before('\n').trim_space()
	fields := line.split('","')
	if fields.len != 2 {
		return error('unexpected whoami output')
	}
	name := fields[0].trim('"')
	sid := fields[1].trim('"')
	if name.len == 0 || !sid.starts_with('S-1-') {
		return error('unexpected whoami output')
	}
	return WindowsPrincipal{
		name: name
		sid:  sid
	}
}

// Trustees (SIDs / SDDL aliases) of every ACE in the DACL of `path`, via
// `icacls /save`, which is locale independent (unlike the printed names).
fn windows_acl_trustees(path string) ![]string {
	out := os.join_path(os.temp_dir(), 'veasel-acl-${rand.bytes(6)!.hex()}.txt')
	defer {
		os.rm(out) or {}
	}
	result := os.exec(['icacls', path, '/save', out])
	if result.exit_code != 0 {
		return error('icacls could not read the ACL of ${path}')
	}
	text := decode_icacls_save(os.read_bytes(out)!)
	for line in text.replace('\r', '').split('\n') {
		trimmed := line.trim_space()
		// The preceding line is the object name, which on drive D: also
		// starts with `D:`; a DACL is `D:` followed by flags or an ACE.
		if trimmed.starts_with('D:') && !trimmed.starts_with('D:\\')
			&& !trimmed.starts_with('D:/') {
			return parse_sddl_trustees(trimmed)
		}
	}
	return error('icacls reported no DACL for ${path}')
}

// A local account's domain part is this machine's name; only then can
// machine-relative aliases (LA, LG) be expanded from the user's SID.
fn (p WindowsPrincipal) is_local() bool {
	machine := os.getenv('COMPUTERNAME').to_lower()
	return machine.len > 0 && p.name.all_before('\\').to_lower() == machine
}

fn windows_acl_is_private(path string) ! {
	me := current_windows_principal()!
	trustees := windows_acl_trustees(path)!
	if bad := first_disallowed_trustee(trustees, me.sid, me.is_local()) {
		// Principals are SIDs/aliases, not secrets: list them so a CI log
		// shows exactly what icacls printed.
		return error('${path} grants access to ${bad}; only the current user (and SYSTEM/Administrators) may hold an entry. user=${me.sid} local=${me.is_local()} trustees=${trustees}')
	}
}

// Removes inheritance, grants the current user full control, then deletes
// every other entry that is not allowlisted (`/grant:r` only replaces the
// user's own grants, so explicit entries for Everyone etc. must be removed
// by SID). The caller re-verifies afterwards.
fn restrict_windows_acl(path string, is_dir bool) ! {
	me := current_windows_principal()!
	grant := if is_dir { '*${me.sid}:(OI)(CI)F' } else { '*${me.sid}:F' }
	result := os.exec(['icacls', path, '/inheritance:r', '/grant:r', grant])
	if result.exit_code != 0 {
		return error('icacls could not restrict ${path} to the current user')
	}
	for _ in 0 .. 8 {
		trustees := windows_acl_trustees(path)!
		bad := first_disallowed_trustee(trustees, me.sid, me.is_local()) or { return }
		// Never remove the allowlisted current user; an alias that cannot be
		// resolved to a SID cannot be removed either: fail closed.
		sid := resolve_sddl_trustee(bad, me.sid, me.is_local()) or {
			return error('cannot resolve ${bad} to a SID; refusing ${path} (trustees=${trustees})')
		}
		if sid.to_upper() == me.sid.to_upper() {
			return error('refusing to remove the current user from ${path}')
		}
		removed := os.exec(['icacls', path, '/remove', '*${sid}'])
		if removed.exit_code != 0 {
			return error('icacls could not remove ${bad} from ${path}')
		}
	}
}

fn create_private_file_exclusive(path string, content string) ! {
	if os.exists(path) {
		return error('${path} already exists')
	}
	// The parent directory was restricted first, so the new file inherits
	// a user-only ACL; restrict and verify the file itself as well.
	os.write_file(path, content)!
	restrict_windows_acl(path, false) or {
		os.rm(path) or {}
		return err
	}
	windows_acl_is_private(path) or {
		os.rm(path) or {}
		return err
	}
}

fn verify_private_file(path string) ! {
	st := os.lstat(path) or { return error('unable to inspect ${path}: ${err}') }
	if st.get_filetype() != .regular {
		return error('${path} must be a regular file, not a link')
	}
	windows_acl_is_private(path)!
}

fn ensure_private_directory(path string) ! {
	if !os.is_dir(path) {
		os.mkdir_all(path)!
	}
	windows_acl_is_private(path) or {
		restrict_windows_acl(path, true)!
		windows_acl_is_private(path)!
	}
}
