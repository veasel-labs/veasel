module main

import os

// Windows has no POSIX mode bits, so the token is protected by an explicit
// ACL. The data DIRECTORY is restricted first (inheritance removed, only the
// current user granted) so a newly created token file inherits a private ACL
// from its first instant; the file is then restricted again explicitly.
// Startup and every client read verify the ACL by parsing `icacls` output and
// refuse (fail closed) when any principal other than the current user holds
// an entry. Arguments are always passed as arrays (no shell, no environment
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

// Returns the principal of every ACE icacls lists for `path`.
fn windows_acl_principals(path string) ![]string {
	result := os.exec(['icacls', path])
	if result.exit_code != 0 {
		return error('icacls could not read the ACL of ${path}')
	}
	return parse_icacls_principals(path, result.output)
}

// icacls prints `<path> <principal>:(perm)...` then one indented
// `<principal>:(perm)...` line per further ACE, then a localized summary.
fn parse_icacls_principals(path string, output string) []string {
	mut principals := []string{}
	for raw in output.replace('\r', '').split('\n') {
		mut line := raw.trim_space()
		if line.starts_with(path) {
			line = line[path.len..].trim_space()
		}
		idx := line.index(':(') or { continue }
		principal := line[..idx].trim_space()
		if principal.len > 0 {
			principals << principal
		}
	}
	return principals
}

fn windows_acl_is_private(path string) ! {
	me := current_windows_principal()!
	for principal in windows_acl_principals(path)! {
		if principal.to_lower() != me.name.to_lower() && principal != me.sid {
			return error('${path} grants access to ${principal}; only the current user may hold an entry')
		}
	}
}

fn restrict_windows_acl(path string, is_dir bool) ! {
	me := current_windows_principal()!
	grant := if is_dir { '*${me.sid}:(OI)(CI)F' } else { '*${me.sid}:F' }
	result := os.exec(['icacls', path, '/inheritance:r', '/grant:r', grant])
	if result.exit_code != 0 {
		return error('icacls could not restrict ${path} to the current user')
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
