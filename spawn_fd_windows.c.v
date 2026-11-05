module main

#include <io.h>

// C._get_osfhandle is already declared by vlib `os` with a voidptr result.
fn C.SetHandleInformation(voidptr, u32, u32) int

// Windows counterpart of FD_CLOEXEC: clears HANDLE_FLAG_INHERIT (0x1) so a
// spawned server cannot inherit the CLI's saved stdout/stderr copies and
// keep the caller's pipes open after the CLI exits.
fn fd_set_cloexec(fd int) bool {
	handle := C._get_osfhandle(fd)
	if handle == unsafe { voidptr(-1) } {
		return false
	}
	return C.SetHandleInformation(handle, 1, 0) != 0
}
