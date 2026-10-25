module main

#insert "@VEXEROOT/vlib/os/filelock/filelock_helpers.h"
#include <sys/file.h>

fn C.open(&char, int, ...int) int
fn C.close(int) int
fn C.flock(int, int) int

fn new_subagent_preparation_lock(path string) !SubagentPreparationLock {
	prepare_subagent_preparation_lock_file(path)!
	return SubagentPreparationLock{
		path: path
	}
}

fn (mut l SubagentPreparationLock) acquire() ! {
	if l.fd != -1 {
		return error('child workspace preparation lock is already acquired')
	}
	fd := C.open(&char(l.path.str), C.O_CREAT | C.O_RDWR, 0o600)
	if fd == -1 {
		return error('cannot open child workspace preparation lock')
	}
	if C.flock(fd, C.LOCK_EX) != 0 {
		C.close(fd)
		return error('cannot acquire child workspace preparation lock')
	}
	l.fd = fd
	return
}

fn (mut l SubagentPreparationLock) try_acquire() bool {
	if l.fd != -1 {
		return true
	}
	fd := C.open(&char(l.path.str), C.O_CREAT | C.O_RDWR, 0o600)
	if fd == -1 {
		return false
	}
	if C.flock(fd, C.LOCK_EX | C.LOCK_NB) != 0 {
		C.close(fd)
		return false
	}
	l.fd = fd
	return true
}

fn (mut l SubagentPreparationLock) release() bool {
	if l.fd == -1 {
		return false
	}
	C.flock(l.fd, C.LOCK_UN)
	C.close(l.fd)
	l.fd = -1
	return true
}
