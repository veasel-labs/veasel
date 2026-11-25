module main

#include <windows.h>

@[typedef]
struct C.FILETIME {
	dwLowDateTime  u32
	dwHighDateTime u32
}

fn C.OpenProcess(access u32, inherit_handle i32, process_id u32) voidptr

fn C.GetProcessTimes(process_handle voidptr, creation &C.FILETIME, exit &C.FILETIME, kernel &C.FILETIME, user &C.FILETIME) i32

fn C.WaitForSingleObject(handle voidptr, milliseconds u32) u32

fn C.CloseHandle(handle voidptr) i32

fn C.GetLastError() u32

const goal_task_process_query_limited_information = u32(0x1000)
const goal_task_synchronize = u32(0x00100000)
const goal_task_wait_object_0 = u32(0)
const goal_task_wait_timeout = u32(258)
const goal_task_access_denied = u32(5)

fn goal_task_owner_status(pid int) GoalTaskOwnerStatus {
	if pid <= 0 {
		return GoalTaskOwnerStatus{}
	}
	handle := C.OpenProcess(goal_task_process_query_limited_information | goal_task_synchronize, 0, u32(pid))
	if isnil(handle) {
		// Access denied proves the process exists, but the caller cannot verify
		// its start identity. Recovery therefore fails closed to uncertain.
		return GoalTaskOwnerStatus{
			alive: C.GetLastError() == goal_task_access_denied
		}
	}
	defer { _ = C.CloseHandle(handle) }
	wait_result := C.WaitForSingleObject(handle, 0)
	if wait_result == goal_task_wait_object_0 {
		return GoalTaskOwnerStatus{}
	}
	if wait_result != goal_task_wait_timeout {
		return GoalTaskOwnerStatus{
			alive: true
		}
	}
	mut created := C.FILETIME{}
	mut exited := C.FILETIME{}
	mut kernel := C.FILETIME{}
	mut user := C.FILETIME{}
	if C.GetProcessTimes(handle, &created, &exited, &kernel, &user) == 0 {
		return GoalTaskOwnerStatus{
			alive: true
		}
	}
	after_times := C.WaitForSingleObject(handle, 0)
	if after_times == goal_task_wait_object_0 {
		return GoalTaskOwnerStatus{}
	}
	if after_times != goal_task_wait_timeout {
		return GoalTaskOwnerStatus{
			alive: true
		}
	}
	return GoalTaskOwnerStatus{
		alive: true
		identity: 'windows-start:${created.dwHighDateTime}:${created.dwLowDateTime}'
	}
}
