module main

#include <fcntl.h>

fn C.fcntl(int, int, ...int) int

// Marks a descriptor close-on-exec so a spawned server cannot inherit the
// CLI's saved stdout/stderr copies. Without this, the long-lived server
// keeps the caller's pipe write-ends open (as fds 3/4) and downstream pipe
// consumers never observe EOF after the CLI exits.
fn fd_set_cloexec(fd int) bool {
	flags := C.fcntl(fd, C.F_GETFD)
	if flags < 0 {
		return false
	}
	return C.fcntl(fd, C.F_SETFD, flags | C.FD_CLOEXEC) == 0
}
