module main

import os
import uuid

$if !windows {
	fn C.umask(mask int) int
}

fn set_test_umask(mask int) int {
	$if windows {
		return 0
	} $else {
		return C.umask(mask)
	}
}

fn private_file_test_root() string {
	root := os.join_path(os.temp_dir(), 'veasel-private-file-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	return root
}

fn private_file_mode(path string) int {
	return int(os.inode(path).bitmask()) & 0o777
}

// The temporary file must be created owner-only: no window where a secret is
// readable by other users, even with a permissive umask.
fn test_atomic_private_write_is_owner_only_under_permissive_umask() {
	$if windows {
		return
	}
	root := private_file_test_root()
	defer { os.rmdir_all(root) or {} }
	prior := set_test_umask(0)
	defer { set_test_umask(prior) }
	path := os.join_path(root, 'secret.json')
	write_private_file_atomic(path, '{"k":"v"}') or { panic(err) }
	assert os.read_file(path) or { panic(err) } == '{"k":"v"}'
	assert private_file_mode(path) == 0o600
	assert !os.exists('${path}.tmp')
}

// A pre-existing world-readable file at the target is replaced, not reused.
fn test_atomic_private_write_replaces_permissive_existing_target() {
	$if windows {
		return
	}
	root := private_file_test_root()
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'secret.json')
	os.write_file(path, 'old') or { panic(err) }
	os.chmod(path, 0o644) or { panic(err) }
	write_private_file_atomic(path, 'new') or { panic(err) }
	assert os.read_file(path) or { panic(err) } == 'new'
	assert private_file_mode(path) == 0o600
}

// A planted symlink at the temp path must not redirect the write (or chmod)
// onto another file.
fn test_atomic_private_write_does_not_follow_planted_temp_symlink() {
	$if windows {
		return
	}
	root := private_file_test_root()
	defer { os.rmdir_all(root) or {} }
	victim := os.join_path(root, 'victim.txt')
	os.write_file(victim, 'victim-data') or { panic(err) }
	os.chmod(victim, 0o644) or { panic(err) }
	path := os.join_path(root, 'secret.json')
	os.symlink(victim, '${path}.tmp') or { panic(err) }
	write_private_file_atomic(path, 'secret') or { panic(err) }
	assert os.read_file(victim) or { panic(err) } == 'victim-data'
	assert private_file_mode(victim) == 0o644
	assert os.read_file(path) or { panic(err) } == 'secret'
	assert private_file_mode(path) == 0o600
}

// Failure to create the file is an error, never a silent best effort.
fn test_atomic_private_write_fails_closed_without_leaving_temp() {
	$if windows {
		return
	}
	root := private_file_test_root()
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'missing-dir', 'secret.json')
	mut failed := false
	write_private_file_atomic(path, 'secret') or { failed = true }
	assert failed
	assert !os.exists('${path}.tmp')
}

// Refresh-token persistence must go through the same hardened path: it must
// not write through a symlink at the final path.
fn test_oauth_refresh_persist_does_not_write_through_symlink() {
	$if windows {
		return
	}
	root := private_file_test_root()
	defer { os.rmdir_all(root) or {} }
	victim := os.join_path(root, 'victim.txt')
	os.write_file(victim, 'victim-data') or { panic(err) }
	path := os.join_path(root, 'mcp-oauth-refresh.json')
	os.symlink(victim, path) or { panic(err) }
	prior := set_test_umask(0)
	defer { set_test_umask(prior) }
	mut state := new_mcp_oauth_refresh_state(path)
	state.persist(PersistedMCPOAuthRefresh{
		credentials: map[string]MCPOAuthRefreshRecord{}
	}) or { panic(err) }
	assert os.read_file(victim) or { panic(err) } == 'victim-data'
	assert !os.is_link(path)
	assert private_file_mode(path) == 0o600
}
