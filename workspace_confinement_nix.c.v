module main

import os

#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

fn C.openat(dirfd int, path &char, flags int, mode ...int) int
fn C.renameat(olddirfd int, oldpath &char, newdirfd int, newpath &char) int
fn C.unlinkat(dirfd int, path &char, flags int) int
fn C.fstat(fd int, buf &C.stat) int
fn C.fchmod(fd int, mode u32) int
fn C.fsync(fd int) int
fn C.read(fd int, buf voidptr, count u64) i64
fn C.write(fd int, buf voidptr, count u64) i64

// ConfinedLeaf describes an already-opened workspace file. The identity
// (dev, ino) is compared across later re-opens to detect substitution.
struct ConfinedLeaf {
	dev   u64
	ino   u64
	nlink u64
	mode  u32
	size  u64
}

fn confined_fstat(fd int) !ConfinedLeaf {
	mut st := C.stat{}
	if C.fstat(fd, &st) != 0 {
		return error('workspace file cannot be inspected')
	}
	return ConfinedLeaf{
		dev:   st.st_dev
		ino:   st.st_ino
		nlink: st.st_nlink
		mode:  st.st_mode
		size:  st.st_size
	}
}

fn confined_is_regular(mode u32) bool {
	return mode & u32(C.S_IFMT) == u32(C.S_IFREG)
}

// confined_open_dir walks `parents` below `root` one component at a time with
// O_NOFOLLOW, so a symbolic link in any parent position fails instead of being
// followed. The returned descriptor pins the directory: later renames or
// symlink swaps of its path cannot redirect operations made through it.
fn confined_open_dir(root string, parents []string) !int {
	mut fd := C.open(&char(root.str), C.O_RDONLY | C.O_DIRECTORY | C.O_CLOEXEC, 0)
	if fd < 0 {
		return error('workspace root cannot be opened')
	}
	for segment in parents {
		next := C.openat(fd, &char(segment.str), C.O_RDONLY | C.O_DIRECTORY | C.O_NOFOLLOW | C.O_CLOEXEC, 0)
		C.close(fd)
		if next < 0 {
			return error('workspace path must not traverse symbolic links or missing directories')
		}
		fd = next
	}
	return fd
}

fn confined_close(fd int) {
	if fd >= 0 {
		C.close(fd)
	}
}

// confined_fd_path returns the kernel's current path for fd (Linux
// /proc/self/fd). Other POSIX systems return '' and callers fall back to
// comparing device/inode identity of the path against the descriptor.
fn confined_fd_path(fd int) string {
	$if linux {
		link := '/proc/self/fd/${fd}'
		mut buf := []u8{len: 4096}
		n := C.readlink(&char(link.str), &char(buf.data), 4095)
		if n <= 0 {
			return ''
		}
		return buf[..n].bytestr()
	} $else {
		return ''
	}
}

// confined_dir_is_inside re-verifies, after pinning, that the directory fd
// still lives inside root. Linux compares the kernel's current path for the
// descriptor. Other POSIX systems have no portable fd->path query here, so they
// rely on the O_NOFOLLOW descent that created the descriptor (documented gap).
fn confined_dir_is_inside(fd int, root string) bool {
	live := confined_fd_path(fd)
	if live.len == 0 {
		return true
	}
	return live == root || live.starts_with(root.trim_right('/') + '/')
}

// confined_open_leaf opens the final component without following symlinks.
// Returns fd < 0 with exists=false when absent. Non-regular files (FIFO,
// device, directory) are rejected; multi-link files only when for_write (a
// write through a hard link would modify a file that may live outside the tree).
fn confined_open_leaf(dirfd int, leaf string, for_write bool) !(int, bool) {
	fd := C.openat(dirfd, &char(leaf.str), C.O_RDONLY | C.O_NOFOLLOW | C.O_NONBLOCK | C.O_CLOEXEC, 0)
	if fd < 0 {
		if C.errno == C.ENOENT {
			return -1, false
		}
		if C.errno == C.ELOOP {
			return error('workspace path must not be a symbolic link')
		}
		return error('workspace file cannot be opened')
	}
	info := confined_fstat(fd) or {
		C.close(fd)
		return err
	}
	if !confined_is_regular(info.mode) {
		C.close(fd)
		return error('workspace path is not a regular file')
	}
	if for_write && info.nlink > 1 {
		C.close(fd)
		return error('workspace file has multiple hard links and may alias a file outside the workspace')
	}
	return fd, true
}

fn confined_read_fd(fd int, max_bytes int) ![]u8 {
	mut out := []u8{cap: 4096}
	mut chunk := []u8{len: 65_536}
	for {
		n := C.read(fd, chunk.data, u64(chunk.len))
		if n < 0 {
			if C.errno == C.EINTR {
				continue
			}
			return error('workspace file cannot be read')
		}
		if n == 0 {
			break
		}
		if out.len + int(n) > max_bytes {
			return error('workspace file exceeds the ${max_bytes} byte limit')
		}
		out << chunk[..int(n)]
	}
	return out
}

// confined_verify_target is the check-time companion of resolve_workspace_edit_target.
fn confined_verify_target(root string, segments []string) ! {
	dirfd := confined_open_dir(root, segments[..segments.len - 1])!
	defer { confined_close(dirfd) }
	fd, exists := confined_open_leaf(dirfd, segments[segments.len - 1], true)!
	if exists {
		confined_close(fd)
	}
}

// confined_read_text reads a workspace file via an O_NOFOLLOW descriptor,
// bounded by max_bytes, and verifies the open file is the path's real file.
fn confined_read_file(path string, max_bytes int) ![]u8 {
	// The parent is canonicalised; the leaf is deliberately NOT, so a symlink
	// leaf is rejected by O_NOFOLLOW instead of silently followed.
	parent := os.real_path(os.dir(path))
	leaf := os.file_name(path)
	dirfd := C.open(&char(parent.str), C.O_RDONLY | C.O_DIRECTORY | C.O_CLOEXEC, 0)
	if dirfd < 0 {
		return error('workspace file parent cannot be opened')
	}
	defer { confined_close(dirfd) }
	live := confined_fd_path(dirfd)
	if live.len > 0 && live != parent {
		return error('workspace file path changed while it was being opened')
	}
	fd, exists := confined_open_leaf(dirfd, leaf, false)!
	if !exists {
		return error('workspace file does not exist')
	}
	defer { confined_close(fd) }
	info := confined_fstat(fd)!
	if info.size > u64(max_bytes) {
		return error('workspace file exceeds the ${max_bytes} byte limit')
	}
	return confined_read_fd(fd, max_bytes)
}

fn confined_write_all(fd int, content string) ! {
	mut offset := 0
	for offset < content.len {
		n := unsafe { C.write(fd, content.str + offset, u64(content.len - offset)) }
		if n < 0 {
			if C.errno == C.EINTR {
				continue
			}
			return error('unable to write the reviewed workspace edit')
		}
		offset += int(n)
	}
}

fn confined_noop() {}

// confined_write_temp writes content to a fresh O_EXCL temporary file in dirfd
// and renames it over leaf. Returns the new file's identity.
fn confined_write_temp_and_rename(dirfd int, temporary string, leaf string, content string, mode int) !ConfinedLeaf {
	fd := C.openat(dirfd, &char(temporary.str), C.O_WRONLY | C.O_CREAT | C.O_EXCL | C.O_NOFOLLOW | C.O_CLOEXEC,
		0o666)
	if fd < 0 {
		return error('temporary workspace edit file already exists or cannot be created')
	}
	confined_write_all(fd, content) or {
		C.close(fd)
		C.unlinkat(dirfd, &char(temporary.str), 0)
		return err
	}
	if mode >= 0 && C.fchmod(fd, u32(mode)) != 0 {
		C.close(fd)
		C.unlinkat(dirfd, &char(temporary.str), 0)
		return error('unable to preserve workspace file permissions')
	}
	C.fsync(fd)
	info := confined_fstat(fd) or {
		C.close(fd)
		C.unlinkat(dirfd, &char(temporary.str), 0)
		return err
	}
	C.close(fd)
	if C.renameat(dirfd, &char(temporary.str), dirfd, &char(leaf.str)) != 0 {
		C.unlinkat(dirfd, &char(temporary.str), 0)
		return error('unable to replace the reviewed workspace file')
	}
	return info
}

// ConfinedReplace carries the arguments of one reviewed replacement.
struct ConfinedReplace {
	root          string
	leaf          string
	temporary     string
	content       string
	original      string // pre-edit content, restored on failed verification
	expected_hash string
	existed       bool
	mode          int
}

// confined_replace_in_dir performs the replacement through a pinned dirfd, then
// re-verifies the result and rolls back when the target is not the file we
// wrote or the directory left the workspace. after_rename is a test seam.
fn confined_replace_in_dir(dirfd int, req ConfinedReplace, after_rename fn ()) ! {
	if !confined_dir_is_inside(dirfd, req.root) {
		return error('workspace parent directory is outside the workspace root')
	}
	existing_fd, exists := confined_open_leaf(dirfd, req.leaf, true)!
	if exists != req.existed {
		confined_close(existing_fd)
		return error('workspace edit target changed after review')
	}
	if exists {
		bytes := confined_read_fd(existing_fd, max_workspace_edit_bytes) or {
			confined_close(existing_fd)
			return err
		}
		confined_close(existing_fd)
		if workspace_content_hash(bytes.bytestr()) != req.expected_hash {
			return error('workspace file changed after review')
		}
	}
	written := confined_write_temp_and_rename(dirfd, req.temporary, req.leaf, req.content, req.mode)!
	after_rename()
	mut verified := confined_dir_is_inside(dirfd, req.root)
	if verified {
		check_fd, present := confined_open_leaf(dirfd, req.leaf, true) or {
			verified = false
			-1, false
		}
		if present {
			now := confined_fstat(check_fd) or { ConfinedLeaf{} }
			confined_close(check_fd)
			if now.ino != written.ino || now.dev != written.dev {
				verified = false
			}
		} else {
			verified = false
		}
	}
	if verified {
		return
	}
	if req.existed {
		confined_write_temp_and_rename(dirfd, req.temporary, req.leaf, req.original, req.mode) or {}
	} else {
		C.unlinkat(dirfd, &char(req.leaf.str), 0)
	}
	return error('workspace write failed post-write verification and was rolled back')
}

// confined_replace_file resolves the parent chain with O_NOFOLLOW and replaces
// the file at segments (relative to canonical root).
fn confined_replace_file(root string, segments []string, req ConfinedReplace) ! {
	dirfd := confined_open_dir(root, segments[..segments.len - 1])!
	defer { confined_close(dirfd) }
	confined_replace_in_dir(dirfd, req, confined_noop)!
}
