module main

#include <signal.h>

fn C.kill(pid int, sig int) int

// cli_kill_process_group sends SIGKILL to the process group led by pid. ESRCH
// (no members left) is the expected quiet outcome.
fn cli_kill_process_group(pid int) {
	if pid > 1 {
		C.kill(-pid, C.SIGKILL)
	}
}
