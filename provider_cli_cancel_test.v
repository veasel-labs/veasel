module main

import os
import time
import uuid

// #cancel: operation cancel and deadline must stop every installed-CLI runner
// and kill the CLI's whole process group (tools it spawned included). The
// fixture streams one frame and then blocks, like a CLI waiting on a tool.

fn cli_leak_pid_alive(pid int) bool {
	stat := os.read_file('/proc/${pid}/stat') or { return false }
	return !stat.contains(') Z')
}

fn cli_leak_script(dir string) string {
	script := os.join_path(dir, 'blocking-cli.sh')
	os.write_file(script, '#!/bin/sh
echo $$ > "${dir}/leader.pid"
sleep 300 &
echo $! > "${dir}/child.pid"
( sleep 301 & echo $! > "${dir}/grand.pid" )
printf \'{"type":"system","subtype":"init","model":"m","session_id":"s"}\\n\'
wait
') or {
		panic(err)
	}
	os.chmod(script, 0o755) or { panic(err) }
	return script
}

fn test_timed_out_claude_turn_leaves_no_descendants() {
	$if !linux {
		return
	}
	dir := os.join_path(os.temp_dir(), 'veasel-cli-leak-${uuid.new_v4().str()}')
	os.mkdir_all(dir) or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	script := cli_leak_script(dir)
	run_claude_cli_turn(script, dir, 'ask', '', 'hello', 1500, ignore_provider_text_delta,
		deny_all_cli_approvals) or {
		assert err.msg().contains('timed out'), err.msg()
		time.sleep(600 * time.millisecond)
		for name in ['leader', 'child', 'grand'] {
			pid := (os.read_file(os.join_path(dir, '${name}.pid')) or { '0' }).trim_space().int()
			assert pid > 0, name
			assert !cli_leak_pid_alive(pid), '${name} pid ${pid} still running after timeout'
		}
		return
	}
	assert false, 'a blocked CLI turn must time out'
}

struct CliCancelFixture {
	dir    string
	script string
	flag   string
}

fn new_cli_cancel_fixture() CliCancelFixture {
	dir := os.join_path(os.temp_dir(), 'veasel-cli-cancel-${uuid.new_v4().str()}')
	os.mkdir_all(dir) or { panic(err) }
	script := cli_leak_script(dir)
	return CliCancelFixture{
		dir:    dir
		script: script
		flag:   os.join_path(dir, 'cancel.flag')
	}
}

fn (f CliCancelFixture) cancel_after(reason string, delay_ms int) CliCancelFn {
	flag := f.flag
	spawn fn [flag, reason, delay_ms] () {
		time.sleep(delay_ms * time.millisecond)
		os.write_file(flag, reason) or {}
	}()
	return fn [flag] () ?string {
		if os.exists(flag) {
			return os.read_file(flag) or { 'cancelled' }
		}
		return none
	}
}

fn (f CliCancelFixture) assert_everything_gone() {
	time.sleep(400 * time.millisecond)
	for name in ['leader', 'child', 'grand'] {
		pid := (os.read_file(os.join_path(f.dir, '${name}.pid')) or { '0' }).trim_space().int()
		assert pid > 0, name
		assert !cli_leak_pid_alive(pid), '${name} pid ${pid} still running'
	}
}

fn test_claude_turn_cancel_kills_cli_and_descendants_quickly() {
	$if !linux {
		return
	}
	f := new_cli_cancel_fixture()
	defer { os.rmdir_all(f.dir) or {} }
	cancel := f.cancel_after('cancelled', 700)
	started := time.now()
	run_claude_cli_turn_observed(f.script, f.dir, 'ask', '', 'hello', 60_000,
		ignore_provider_text_delta, deny_all_cli_approvals, unsafe { nil }, cancel) or {
		assert err.msg() == 'cancelled', err.msg()
		assert time.since(started) < 5 * time.second
		f.assert_everything_gone()
		return
	}
	assert false, 'cancel must end the turn'
}

fn test_claude_turn_deadline_reports_deadline_and_kills_group() {
	$if !linux {
		return
	}
	f := new_cli_cancel_fixture()
	defer { os.rmdir_all(f.dir) or {} }
	cancel := f.cancel_after('deadline_exceeded', 700)
	run_claude_cli_turn_observed(f.script, f.dir, 'ask', '', 'hello', 60_000,
		ignore_provider_text_delta, deny_all_cli_approvals, unsafe { nil }, cancel) or {
		assert err.msg() == 'deadline_exceeded', err.msg()
		f.assert_everything_gone()
		return
	}
	assert false
}

fn test_codex_turn_cancel_kills_cli_and_descendants() {
	$if !linux {
		return
	}
	f := new_cli_cancel_fixture()
	defer { os.rmdir_all(f.dir) or {} }
	cancel := f.cancel_after('cancelled', 700)
	run_codex_cli_turn_cancellable(f.script, f.dir, 'ask', '', '', 'hello', 60_000,
		ignore_provider_text_delta, deny_all_cli_approvals, cancel) or {
		assert err.msg() == 'cancelled', err.msg()
		f.assert_everything_gone()
		return
	}
	assert false
}

fn test_acp_turn_cancel_kills_cli_and_descendants() {
	$if !linux {
		return
	}
	f := new_cli_cancel_fixture()
	defer { os.rmdir_all(f.dir) or {} }
	cancel := f.cancel_after('cancelled', 700)
	run_acp_cli_turn_cancellable(f.script, ['acp'], f.dir, []AcpSessionConfig{}, '', 'hello',
		60_000, ignore_provider_text_delta, deny_all_cli_approvals, cancel) or {
		assert err.msg() == 'cancelled', err.msg()
		f.assert_everything_gone()
		return
	}
	assert false
}

fn test_cancel_reason_is_none_for_nil_and_idle_callbacks() {
	assert cli_cancel_reason(unsafe { nil }) == none
	idle := fn () ?string {
		return none
	}
	assert cli_cancel_reason(idle) == none
}

fn test_expire_pending_cli_approvals_settles_only_pending_rows() {
	root := os.join_path(os.temp_dir(), 'veasel-cli-approvals-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	session := store.create_session(SessionInput{ title: 'cli', directory: root }) or { panic(err) }
	pending := store.create_cli_tool_approval(session.id, 'r1', 'Edit', '{}') or { panic(err) }
	approved := store.create_cli_tool_approval(session.id, 'r2', 'Bash', '{}') or { panic(err) }
	store.decide_cli_tool_approval(session.id, approved.id, true) or { panic(err) }
	store.expire_pending_cli_tool_approvals(session.id) or { panic(err) }
	assert (store.get_cli_tool_approval(pending.id) or { panic(err) }).status == 'expired'
	assert (store.get_cli_tool_approval(approved.id) or { panic(err) }).status == 'approved'
	assert (store.list_pending_cli_tool_approvals(session.id) or { panic(err) }).len == 0
}

// Production wiring: the CLI cancel closure is built from the operation's
// turn context, exactly as complete_agent_with_model_override does, so the
// operation cancel API ends the CLI turn and its process group.
fn test_operation_cancel_ends_cli_turn_and_kills_process_group() {
	$if !linux {
		return
	}
	f := new_cli_cancel_fixture()
	defer { os.rmdir_all(f.dir) or {} }
	store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	mut app := new_app(store, os.join_path(f.dir, 'plugins'))
	defer { app.close() }
	operation_id := uuid.new_v4().str()
	_, mut turn_ctx, cancel, _ := app.begin_turn_operation('session-cli', operation_id) or {
		panic(err)
	}
	defer { cancel() }
	cli_cancel := fn [mut turn_ctx] () ?string {
		return turn_context_error(mut turn_ctx)
	}
	spawn fn [app, operation_id] () {
		time.sleep(700 * time.millisecond)
		app.cancel_turn_operation('session-cli', operation_id) or {}
	}()
	started := time.now()
	run_claude_cli_turn_observed(f.script, f.dir, 'ask', '', 'hello', 60_000,
		ignore_provider_text_delta, deny_all_cli_approvals, unsafe { nil }, cli_cancel) or {
		assert err.msg() == 'cancelled', err.msg()
		assert time.since(started) < 5 * time.second
		f.assert_everything_gone()
		app.finish_turn_operation(operation_id)
		return
	}
	assert false
}
