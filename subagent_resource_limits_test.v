module main

import context as vcontext
import os
import time
import uuid

// Delegated-child resource-limit tests. They run only inside the Bubblewrap
// sandbox (never directly on the host) with short timeouts; the nproc limit is
// proven with a bounded loop before the fork bomb is attempted.

struct ChildSandboxFixture {
	base  string
	root  string
	child string
}

fn child_sandbox_fixture() ?ChildSandboxFixture {
	$if !linux {
		return none
	}
	if !bubblewrap_available() {
		return none
	}
	base := os.join_path(os.temp_dir(), 'veasel-child-limits-${uuid.new_v4().str()}')
	root := os.join_path(base, 'parent')
	child := os.join_path(root, 'child')
	os.mkdir_all(child) or { panic(err) }
	return ChildSandboxFixture{
		base:  os.real_path(base)
		root:  os.real_path(root)
		child: os.real_path(child)
	}
}

fn run_child_command(fixture ChildSandboxFixture, command string, timeout int, allow_network bool) ShellCommandResult {
	mut background := vcontext.background()
	mut turn_ctx, cancel := vcontext.with_timeout(mut background, time.Duration(timeout + 8) * time.second)
	defer { cancel() }
	return run_linux_sandboxed_shell_command_with_write_scope(mut turn_ctx, fixture.root, 'child',
		ShellCommandSummary{
			command:         command
			cwd:             'child'
			timeout_seconds: timeout
		}, LinuxShellSandboxOptions{
			purpose:            'Delegated child command'
			fail_closed:        true
			filter_environment: true
			allow_network:      allow_network
		}, fixture.child)
}

fn host_process_count(marker string) int {
	result := os.execute('pgrep -f -c -- ${marker}')
	return result.output.trim_space().int()
}

fn test_child_timeout_kills_descendants_including_setsid_escapes() {
	fixture := child_sandbox_fixture() or { return }
	defer { os.rmdir_all(fixture.base) or {} }
	result := run_child_command(fixture,
		'sleep 7771 & setsid sleep 7772 & (sleep 7773 &) ; sleep 7774', 1, false)
	assert result.status == 'timed_out', result.output
	time.sleep(500 * time.millisecond)
	assert host_process_count('"[s]leep 777[1-4]"') == 0
}

fn test_child_output_flood_is_capped_and_killed() {
	fixture := child_sandbox_fixture() or { return }
	defer { os.rmdir_all(fixture.base) or {} }
	started := time.now()
	result := run_child_command(fixture, 'yes veasel', 20, false)
	assert result.status == 'output_limited', result.status
	assert result.output.len <= max_shell_command_output_bytes + shell_output_limited_marker.len
	assert time.since(started) < 15 * time.second
}

fn test_child_network_is_denied_even_when_caller_asks_for_it() {
	fixture := child_sandbox_fixture() or { return }
	defer { os.rmdir_all(fixture.base) or {} }
	result := run_child_command(fixture, 'cat /proc/net/dev', 5, true)
	assert result.status == 'succeeded', result.output
	mut interfaces := []string{}
	for line in result.output.split_into_lines() {
		if line.contains(':') && !line.contains('|') {
			interfaces << line.all_before(':').trim_space()
		}
	}
	assert interfaces.all(it == 'lo'), interfaces.str()
}

fn test_child_process_count_is_capped() {
	fixture := child_sandbox_fixture() or { return }
	defer { os.rmdir_all(fixture.base) or {} }
	// The subshell keeps spawning sleepers until fork() fails at the nproc cap,
	// which kills that subshell; the outer shell then records that it was capped.
	run_child_command(fixture,
		r'(i=0; while true; do sleep 2 & i=$((i+1)); echo $i > count.txt; done) 2>/dev/null; echo capped > capped.txt',
		8, false)
	count := (os.read_file(os.join_path(fixture.child, 'count.txt')) or { '0' }).trim_space().int()
	assert count >= 100 && count <= 256, 'spawned before cap: ${count}'
	assert os.exists(os.join_path(fixture.child, 'capped.txt'))
}

fn test_child_fork_bomb_is_bounded_by_limits_and_timeout() {
	fixture := child_sandbox_fixture() or { return }
	defer { os.rmdir_all(fixture.base) or {} }
	// Precondition: the nproc cap must be effective before a real bomb runs.
	probe := run_child_command(fixture, 'grep "Max processes" /proc/self/limits', 5, false)
	assert probe.output.contains('256'), probe.output
	started := time.now()
	result := run_child_command(fixture, 'b() { b | b & }; b; sleep 5', 2, false)
	assert result.status in ['timed_out', 'failed', 'succeeded'], result.status
	assert time.since(started) < 12 * time.second
	time.sleep(500 * time.millisecond)
	assert host_process_count('"[b]wrap.*veasel-child-limits-"') == 0
}

fn test_child_file_size_and_worktree_quota_are_enforced() {
	fixture := child_sandbox_fixture() or { return }
	defer { os.rmdir_all(fixture.base) or {} }
	limit := run_child_command(fixture, 'cat /proc/self/limits', 5, false)
	assert limit.status == 'succeeded', limit.output
	assert limit.output.contains('Max processes') && limit.output.contains('256'), limit.output
	assert limit.output.contains('Max open files') && limit.output.contains('1024'), limit.output
	assert limit.output.contains('Max file size') && limit.output.contains('1073741824'), limit.output
	core := limit.output.split_into_lines().filter(it.starts_with('Max core file size'))
	assert core.len == 1 && core[0].contains(' 0 '), limit.output
	assert !workspace_tree_exceeds(fixture.child, 1024)
	os.write_file(os.join_path(fixture.child, 'blob'), 'x'.repeat(4096)) or { panic(err) }
	assert workspace_tree_exceeds(fixture.child, 1024)
	assert !workspace_tree_exceeds(fixture.child, 8192)
	// A symlink to a large outside file must not count as worktree bytes.
	os.write_file(os.join_path(fixture.base, 'huge'), 'y'.repeat(100_000)) or { panic(err) }
	os.symlink(os.join_path(fixture.base, 'huge'), os.join_path(fixture.child, 'link')) or { panic(err) }
	assert !workspace_tree_exceeds(fixture.child, 8192)
}

fn test_child_limits_are_dialect_independent_under_dash() {
	fixture := child_sandbox_fixture() or { return }
	defer { os.rmdir_all(fixture.base) or {} }
	dash := os.find_abs_path_of_executable('dash') or { return }
	// The limits come from prlimit, not from shell builtins, so a dash
	// subshell inherits them and the run does not fail on `ulimit -u`.
	result := run_child_command(fixture, '${dash} -c "grep \"Max processes\" /proc/self/limits"', 5, false)
	assert result.status == 'succeeded', result.output
	assert result.output.contains('256'), result.output
}
