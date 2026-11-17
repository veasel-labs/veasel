module main

import os

// Windows has no POSIX mode bits. The token is created under the user's
// profile (which inherits a user-only ACL) and, best effort, its inherited
// ACL entries are removed so only the current user keeps access. If icacls
// fails the backend refuses to start rather than serve with an unprotected
// credential (fail closed). See docs/security/backend-caller-auth.md.
fn create_private_file_exclusive(path string, content string) ! {
	if os.exists(path) {
		return error('${path} already exists')
	}
	os.write_file(path, content)!
	restrict_windows_acl(path) or {
		os.rm(path) or {}
		return err
	}
}

fn restrict_windows_acl(path string) ! {
	user := os.getenv('USERNAME')
	if user.len == 0 {
		return error('USERNAME is not set; cannot restrict the ACL of ${path}')
	}
	result := os.execute('icacls "${path}" /inheritance:r /grant:r "${user}:F"')
	if result.exit_code != 0 {
		return error('icacls could not restrict ${path} to the current user')
	}
}

fn verify_private_file(path string) ! {
	st := os.lstat(path) or { return error('unable to inspect ${path}: ${err}') }
	if st.get_filetype() != .regular {
		return error('${path} must be a regular file, not a link')
	}
}

fn ensure_private_directory(path string) ! {
	if !os.is_dir(path) {
		os.mkdir_all(path)!
	}
}
