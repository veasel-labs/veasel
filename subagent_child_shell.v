module main

import context as vcontext
import os
import uuid

// Delegated child shell (#747). A shell command in a child (subagent) session
// never uses the ordinary approved-shell path: it runs only through the Linux
// Bubblewrap child sandbox (network denied, writable scope narrowed to the
// child worktree, prlimit limits) and is refused on every other platform. The
// parent's explicit unsandboxed opt-in is deliberately NOT consulted here, so a
// child can never be widened beyond the sandbox.

fn current_platform_name() string {
	return $if linux {
		'linux'
	} $else $if macos {
		'macos'
	} $else $if windows {
		'windows'
	} $else {
		'other'
	}
}

// delegated_child_shell_refusal returns the reason a delegated child command
// must not start, or none when every required backend is present. It is a pure
// function of its inputs so platform refusals are testable on Linux CI.
fn delegated_child_shell_refusal(platform string, bwrap_available bool, prlimit_available bool) ?string {
	if platform != 'linux' {
		return 'Delegated child shell execution is only available on Linux (Bubblewrap + prlimit); this platform has no child sandbox, so no process was started.'
	}
	if !bwrap_available {
		return 'Delegated child shell execution requires Bubblewrap (${shell_sandbox_install_hint('linux')}); no process was started.'
	}
	if !prlimit_available {
		return 'Delegated child shell execution requires prlimit from util-linux for its resource limits; no process was started.'
	}
	return none
}

fn prlimit_available() bool {
	os.find_abs_path_of_executable('prlimit') or { return false }
	return true
}

// run_delegated_child_shell_command runs command inside the child worktree
// through the fail-closed child sandbox. worktree must be the canonical child
// worktree directory (<data>/subagent-worktrees/<run id>).
fn run_delegated_child_shell_command(mut turn_ctx vcontext.Context, worktree string,
	command ShellCommandSummary) ShellCommandResult {
	if reason := delegated_child_shell_refusal(current_platform_name(), bubblewrap_available(),
		prlimit_available())
	{
		return ShellCommandResult{
			status:    'failed'
			exit_code: -1
			output:    reason
		}
	}
	canonical := os.real_path(worktree)
	if canonical != worktree || os.is_link(worktree) || !os.is_dir(worktree) {
		return ShellCommandResult{
			status:    'failed'
			exit_code: -1
			output:    'Delegated child shell refused a non-canonical child worktree; no process was started.'
		}
	}
	draft := prepare_shell_command(canonical, command.command, command.cwd, command.timeout_seconds) or {
		return ShellCommandResult{
			status:    'failed'
			exit_code: -1
			output:    'Delegated child shell refused the command or working directory: ${err.msg()}; no process was started.'
		}
	}
	// Sealed snapshot (#642): the sandbox never receives the live worktree.
	// A private copy is sealed first (links rejected, fresh single-link
	// files), the command runs against the copy, and its changes are
	// verified back into the worktree afterwards. A same-UID process
	// mutating the live tree between the old walk and the launch can no
	// longer smuggle a link into the writable scope.
	sealed := seal_child_worktree_snapshot(canonical) or {
		return ShellCommandResult{
			status:    'failed'
			exit_code: -1
			output:    'Delegated child shell refused to seal the child worktree: ${err.msg()}; no process was started.'
		}
	}
	run_dir := os.file_name(sealed.dir)
	cwd := if draft.cwd == '.' { run_dir } else { os.join_path(run_dir, draft.cwd) }
	result := run_linux_sandboxed_shell_command_with_write_scope(mut turn_ctx,
		os.dir(canonical), cwd, ShellCommandSummary{
			id:              command.id
			command:         draft.command
			cwd:             cwd
			timeout_seconds: draft.timeout_seconds
		}, LinuxShellSandboxOptions{
			purpose:            'Delegated child command'
			fail_closed:        true
			filter_environment: true
			allow_network:      false
			limit_resources:    true
		}, sealed.dir)
	sync := sync_sealed_snapshot_back(canonical, sealed)
	if sync.err.len > 0 {
		// Preserve the sealed tree for review instead of guessing.
		return ShellCommandResult{
			...result
			output: result.output +
				'\n[veasel] Sealed snapshot sync-back stopped (${sync.err}); changes already applied stay applied, the snapshot is preserved at ${sealed.dir} for review, and nothing further was copied.'
		}
	}
	os.rmdir_all(sealed.dir) or {}
	return ShellCommandResult{
		...result
		output: result.output +
			'\n[veasel] Sealed snapshot: ${sync.changed} file change(s) synced back to the child worktree.'
	}
}

const sealed_snapshot_max_files = 20_000
const sealed_snapshot_max_total_bytes = i64(256 * 1024 * 1024)

struct SealedSnapshot {
mut:
	dir      string
	manifest map[string]string // relative path -> content hash at seal time
	modes    map[string]int
	links    map[string]string // relative path -> symlink target at seal time
}

struct SealedSyncResult {
	changed int
	err     string
}

fn sealed_mode_is_link(mode u32) bool {
	return mode & 0o170000 == 0o120000
}

fn sealed_mode_is_dir(mode u32) bool {
	return mode & 0o170000 == 0o040000
}

fn sealed_mode_is_regular(mode u32) bool {
	return mode & 0o170000 == 0o100000
}

// seal_child_worktree_snapshot copies the worktree into a fresh private
// directory next to it, rejecting links and non-regular entries. Copied
// files are new single-link inodes, so nothing inside can alias a file
// outside the snapshot.
fn seal_child_worktree_snapshot(worktree string) !SealedSnapshot {
	parent := os.dir(worktree)
	snapshot := os.join_path(parent, '.veasel-sealed-${uuid.new_v4().str()}')
	os.mkdir_all(snapshot) or { return error('snapshot directory cannot be created') }
	mut sealed := SealedSnapshot{
		dir:      snapshot
		manifest: map[string]string{}
		modes:    map[string]int{}
		links:    map[string]string{}
	}
	mut budget := [i64(0), i64(0)] // files, bytes
	seal_copy_into(worktree, snapshot, '', mut sealed, mut budget) or {
		os.rmdir_all(snapshot) or {}
		return err
	}
	return sealed
}

fn seal_copy_into(src_dir string, dst_dir string, rel string, mut sealed SealedSnapshot, mut budget []i64) ! {
	entries := os.ls(src_dir) or { return error('child worktree cannot be listed while sealing') }
	for entry in entries {
		src := os.join_path(src_dir, entry)
		dst := os.join_path(dst_dir, entry)
		child_rel := if rel == '' { entry } else { '${rel}/${entry}' }
		info := os.lstat(src) or { return error('child worktree entry cannot be inspected while sealing') }
		if sealed_mode_is_link(info.mode) {
			// Links are recreated as links inside the snapshot. They cannot
			// create a write escape: the sandbox writable scope is only the
			// snapshot, and sync-back refuses new or changed links.
			target := os.readlink(src) or { return error('child worktree link cannot be read while sealing') }
			os.symlink(target, dst) or { return error('snapshot link cannot be created') }
			sealed.links[child_rel] = target
			continue
		}
		if sealed_mode_is_dir(info.mode) {
			os.mkdir(dst) or { return error('snapshot directory cannot be created') }
			seal_copy_into(src, dst, child_rel, mut sealed, mut budget)!
			continue
		}
		if !sealed_mode_is_regular(info.mode) {
			return error('child worktree contains a non-regular entry at ${child_rel}')
		}
		if info.size < 0 || budget[1] + info.size > sealed_snapshot_max_total_bytes {
			return error('child worktree exceeds the sealed snapshot size limit')
		}
		budget[0]++
		if budget[0] > sealed_snapshot_max_files {
			return error('child worktree exceeds the sealed snapshot file limit')
		}
		bytes := os.read_bytes(src) or { return error('child worktree file cannot be read while sealing') }
		budget[1] += i64(bytes.len)
		os.write_file(dst, bytes.bytestr()) or { return error('snapshot file cannot be written') }
		mode := int(info.mode & 0o777)
		if mode != 0 {
			os.chmod(dst, mode) or {}
		}
		sealed.manifest[child_rel] = workspace_content_hash(bytes.bytestr())
		sealed.modes[child_rel] = mode
	}
}

// sync_sealed_snapshot_back applies the snapshot's changes to the live
// worktree: changed/new files are copied back, sealed files the command
// deleted are removed, and anything that became a link inside the sandbox
// is refused (never copied through). On any refusal nothing is deleted
// from the snapshot, so the caller can preserve it for review.
fn sync_sealed_snapshot_back(worktree string, sealed SealedSnapshot) SealedSyncResult {
	mut changed := 0
	mut seen := map[string]bool{}
	mut pending := []string{}
	collect_snapshot_files(sealed.dir, '', mut pending)
	for rel in pending {
		seen[rel] = true
		src := os.join_path(sealed.dir, ...rel.split('/'))
		info := os.lstat(src) or {
			return SealedSyncResult{ err: 'snapshot entry cannot be inspected' }
		}
		if sealed_mode_is_link(info.mode) {
			target := os.readlink(src) or {
				return SealedSyncResult{ err: 'snapshot link cannot be read' }
			}
			known_target := sealed.links[rel] or { '' }
			if rel in sealed.links && known_target == target {
				continue // pre-existing link, untouched
			}
			return SealedSyncResult{
				err: 'the command created or changed a symbolic link at ${rel}'
			}
		}
		if !sealed_mode_is_regular(info.mode) {
			return SealedSyncResult{
				err: 'the command left a non-regular entry at ${rel}'
			}
		}
		bytes := os.read_bytes(src) or {
			return SealedSyncResult{ err: 'snapshot file cannot be read' }
		}
		content := bytes.bytestr()
		if rel in sealed.manifest && sealed.manifest[rel] == workspace_content_hash(content) {
			continue
		}
		dst := os.join_path(worktree, ...rel.split('/'))
		parent := os.dir(dst)
		if !verify_snapshot_parent(worktree, parent) {
			return SealedSyncResult{
				err: 'the child worktree path for ${rel} is no longer a plain directory inside the worktree'
			}
		}
		os.mkdir_all(parent) or { return SealedSyncResult{ err: 'worktree directory cannot be created' } }
		if !verify_snapshot_parent(worktree, parent) {
			return SealedSyncResult{
				err: 'the child worktree path for ${rel} changed while being prepared'
			}
		}
		// A multiply-linked destination must be replaced, not truncated:
		// writing in place would alias the change into the linked file.
		if dst_info := os.lstat(dst) {
			if dst_info.nlink > 1 || sealed_mode_is_link(dst_info.mode) {
				os.rm(dst) or { return SealedSyncResult{ err: 'worktree file cannot be replaced' } }
			}
		}
		os.write_file(dst, content) or { return SealedSyncResult{ err: 'worktree file cannot be written' } }
		if mode := sealed.modes[rel] {
			os.chmod(dst, mode) or {}
		}
		changed++
	}
	for rel, _ in sealed.manifest {
		if rel in seen {
			continue
		}
		dst := os.join_path(worktree, ...rel.split('/'))
		if os.is_link(dst) {
			return SealedSyncResult{
				err: 'the child worktree entry at ${rel} became a symbolic link'
			}
		}
		os.rm(dst) or { return SealedSyncResult{ err: 'worktree file cannot be removed' } }
		changed++
	}
	for rel, _ in sealed.links {
		if rel in seen {
			continue
		}
		// The command deleted a pre-existing link inside the sandbox:
		// mirror the deletion, never follow it.
		dst := os.join_path(worktree, ...rel.split('/'))
		os.rm(dst) or { return SealedSyncResult{ err: 'worktree link cannot be removed' } }
		changed++
	}
	return SealedSyncResult{
		changed: changed
	}
}

fn collect_snapshot_files(dir string, rel string, mut out []string) {
	entries := os.ls(dir) or { return }
	for entry in entries {
		path := os.join_path(dir, entry)
		child_rel := if rel == '' { entry } else { '${rel}/${entry}' }
		info := os.lstat(path) or { continue }
		if sealed_mode_is_dir(info.mode) && !sealed_mode_is_link(info.mode) {
			collect_snapshot_files(path, child_rel, mut out)
		} else {
			out << child_rel
		}
	}
}

// verify_snapshot_parent: parent is worktree or below it, and no component
// below the worktree is a symbolic link.
fn verify_snapshot_parent(worktree string, parent string) bool {
	if parent != worktree && !parent.starts_with(worktree + os.path_separator) {
		return false
	}
	if os.is_link(parent) {
		return false
	}
	mut current := parent
	for current.len > worktree.len {
		if os.is_link(current) {
			return false
		}
		current = os.dir(current)
	}
	return true
}

// child_subagent_run_id returns the subagent run whose child session is
// session_id, or '' for an ordinary session. A lookup failure is an error so
// callers fail closed instead of treating a child as an ordinary session.
fn (mut store Store) child_subagent_run_id(session_id string) !string {
	store.mu.lock()
	defer { store.mu.unlock() }
	rows := store.db.exec_param_many('SELECT id FROM subagent_runs WHERE child_session_id = ? LIMIT 1',
		[session_id])!
	if rows.len == 0 {
		return ''
	}
	return rows[0].val(0)
}

// run_session_shell_command is the single execution choke point for approved
// shell commands: child sessions are routed to the child sandbox, everything
// else keeps the ordinary approved/autonomous behaviour.
fn (app &App) run_session_shell_command(mut turn_ctx vcontext.Context, session_id string, root string,
	command ShellCommandSummary, sanitize_environment bool) ShellCommandResult {
	mut store := app.store
	run_id := store.child_subagent_run_id(session_id) or {
		return ShellCommandResult{
			status:    'failed'
			exit_code: -1
			output:    'Unable to determine whether this session is a delegated child; no process was started.'
		}
	}
	if run_id.len == 0 {
		return run_approved_shell_command_with_context(mut turn_ctx, root, command, sanitize_environment)
	}
	expected := os.join_path(os.dir(os.real_path(store.path)), 'subagent-worktrees', run_id)
	if !os.is_dir(expected) || os.real_path(root) != os.real_path(expected) {
		return ShellCommandResult{
			status:    'failed'
			exit_code: -1
			output:    'The child workspace is unavailable or no longer matches its durable run; no process was started.'
		}
	}
	return run_delegated_child_shell_command(mut turn_ctx, os.real_path(expected), command)
}
