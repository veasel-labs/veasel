module main

import os

#include <fcntl.h>
#include <unistd.h>

// C.open and C.close are declared in subagent_preparation_lock_nix.c.v.
fn C.fsync(int) int

// Creates `path` with O_CREAT|O_EXCL and mode 0600 from the first instant it
// exists, so no other local user can ever observe the secret with a wider
// mode. The umask can only remove bits, never add them.
fn create_private_file_exclusive(path string, content string) ! {
	fd := C.open(&char(path.str), C.O_CREAT | C.O_EXCL | C.O_WRONLY | C.O_CLOEXEC, 0o600)
	if fd < 0 {
		return error('unable to create ${path} exclusively with mode 0600')
	}
	os.fd_write(fd, content)
	synced := C.fsync(fd) == 0
	os.fd_close(fd)
	if !synced {
		os.rm(path) or {}
		return error('unable to flush ${path} to disk')
	}
}

// Verifies a secret file is a regular, non-symlink file owned by this user
// with no group/world access. Anything else fails closed.
fn verify_private_file(path string) ! {
	st := os.lstat(path) or { return error('unable to inspect ${path}: ${err}') }
	if st.get_filetype() != .regular {
		return error('${path} must be a regular file, not a symlink or special file')
	}
	if st.uid != u32(os.getuid()) {
		return error('${path} is not owned by the current user')
	}
	if st.mode & 0o077 != 0 {
		return error('${path} is accessible by group or other users (mode ${(st.mode & 0o777).hex()}); run `chmod 600` on it or rotate the token with `veasel token rotate`')
	}
}

// Ensures the data directory exists and is not writable by anyone else
// (a writable parent would let another user swap the token file).
fn ensure_private_directory(path string) ! {
	if !os.is_dir(path) {
		os.mkdir_all(path, mode: 0o700) or {
			if !os.is_dir(path) {
				return err
			}
		}
	}
	st := os.stat(path) or { return error('unable to inspect ${path}: ${err}') }
	if st.uid != u32(os.getuid()) {
		return error('${path} is not owned by the current user')
	}
	if st.mode & 0o077 != 0 {
		os.chmod(path, 0o700) or {}
		again := os.stat(path) or { return error('unable to inspect ${path}: ${err}') }
		if again.mode & 0o022 != 0 {
			return error('${path} is writable by other users and could not be restricted to mode 0700')
		}
	}
}

// rename(2) atomically replaces an existing destination.
fn replace_file_atomic(src string, dst string) ! {
	os.rename(src, dst)!
}
