module main

import os

#include <errno.h>

#include <signal.h>

#include <unistd.h>

$if macos {
	#flag darwin -lproc
	#include <libproc.h>
}

fn C.kill(pid i32, signal i32) int

@[c_extern]
fn C.proc_pidinfo(pid int, flavor int, arg u64, info voidptr, size int) int

const macos_process_zombie = u32(5) // XNU SZOMB process status.

@[typedef]
struct C.GoalTaskProcBsdInfo {
	flags        u32
	status       u32
	xstatus      u32
	pid          u32
	ppid         u32
	uid          u32
	gid          u32
	ruid         u32
	rgid         u32
	svuid        u32
	svgid        u32
	reserved     u32
	comm         [16]u8
	name         [32]u8
	nfiles       u32
	pgid         u32
	pjobc        u32
	tdev         u32
	tpgid        u32
	nice         i32
	start_tvsec  u64
	start_tvusec u64
}

fn goal_task_owner_status(pid int) GoalTaskOwnerStatus {
	if pid <= 0 {
		return GoalTaskOwnerStatus{}
	}
	result := C.kill(i32(pid), 0)
	if result != 0 && C.errno != C.EPERM {
		return GoalTaskOwnerStatus{}
	}
	$if linux {
		stat := os.read_file('/proc/${pid}/stat') or {
			if C.kill(i32(pid), 0) != 0 && C.errno != C.EPERM {
				return GoalTaskOwnerStatus{}
			}
			return GoalTaskOwnerStatus{
				alive: true
			}
		}
		close_paren := stat.last_index(')') or {
			return GoalTaskOwnerStatus{
				alive: true
			}
		}
		fields := stat[close_paren + 1..].fields()
		if fields.len <= 19 {
			return GoalTaskOwnerStatus{
				alive: true
			}
		}
		if fields[0] in ['Z', 'X', 'x'] {
			return GoalTaskOwnerStatus{}
		}
		return GoalTaskOwnerStatus{
			alive: true
			identity: 'linux-start:${fields[19]}'
		}
	}
	$if macos {
		mut info := C.GoalTaskProcBsdInfo{}
		bytes := C.proc_pidinfo(i32(pid), 3, 0, &info, int(sizeof(info)))
		if bytes < int(sizeof(info)) {
			return GoalTaskOwnerStatus{
				alive: true
			}
		}
		if info.status == macos_process_zombie {
			return GoalTaskOwnerStatus{}
		}
		return GoalTaskOwnerStatus{
			alive: true
			identity: 'macos-start:${info.start_tvsec}:${info.start_tvusec}'
		}
	}
	// Other POSIX systems currently have no verified process-start identity.
	// Claims are refused when this identity is unavailable.
	return GoalTaskOwnerStatus{
		alive: true
	}
}
