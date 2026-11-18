module main

import os

#include <windows.h>

fn C.GetFileAttributesW(path &u16) u32

const windows_attribute_reparse_point = u32(0x400)
const windows_invalid_file_attributes = u32(0xFFFFFFFF)

// confined_is_reparse_point is true for symbolic links, junctions and other
// reparse points. Missing paths return false.
fn confined_is_reparse_point(path string) bool {
	attributes := C.GetFileAttributesW(path.to_wide())
	if attributes == windows_invalid_file_attributes {
		return false
	}
	return attributes & windows_attribute_reparse_point != 0
}

// confined_verify_target rejects reparse points (symlinks, junctions) at every
// component. Windows has no openat/O_NOFOLLOW here, so this is check-time only;
// it is documented as weaker than the POSIX descriptor-pinned path.
fn confined_verify_target(root string, segments []string) ! {
	mut current := root
	for segment in segments {
		current = os.join_path(current, segment)
		if confined_is_reparse_point(current) {
			return error('workspace path must not traverse symbolic links, junctions or reparse points')
		}
	}
}

fn confined_read_file(path string, max_bytes int) ![]u8 {
	if confined_is_reparse_point(path) {
		return error('workspace file must not be a reparse point')
	}
	size := os.stat(path)!.size
	if size > u64(max_bytes) {
		return error('workspace file exceeds the ${max_bytes} byte limit')
	}
	bytes := os.read_bytes(path)!
	if bytes.len > max_bytes {
		return error('workspace file exceeds the ${max_bytes} byte limit')
	}
	return bytes
}
