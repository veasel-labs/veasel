module main

import os.filelock

fn new_subagent_preparation_lock(path string) !SubagentPreparationLock {
	prepare_subagent_preparation_lock_file(path)!
	return SubagentPreparationLock{
		path:         path
		windows_lock: filelock.new_file(path, filelock.LockOptions{})
	}
}

fn (mut l SubagentPreparationLock) acquire() ! {
	l.windows_lock.acquire()!
}

fn (mut l SubagentPreparationLock) try_acquire() bool {
	return l.windows_lock.try_acquire()
}

fn (mut l SubagentPreparationLock) release() bool {
	return l.windows_lock.release()
}
