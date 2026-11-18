module main

// Workspace confinement helpers shared by every platform.
//
// Path-string checks (`path_is_within`, `os.is_link`) are advisory: a path can
// change between the check and the use. The POSIX implementation in
// workspace_confinement_nix.c.v therefore pins every directory component with
// an `O_NOFOLLOW` descriptor and performs the final read/write through those
// descriptors. The Windows implementation rejects reparse points.

// workspace_protected_directory_names are never editable through Veasel for any
// session (parent or child).
const workspace_protected_directory_names = ['.git', '.hg', '.svn', 'node_modules', 'vendor']

// workspace_sensitive_names can change what git, the shell or CI later
// executes (hooks, filter attributes, submodule URLs, direnv, workflows). Child
// and subagent worktrees may not write them; the parent must review them by
// hand because they are never imported by subagent integration.
const workspace_sensitive_names = ['.gitattributes', '.gitmodules', '.gitignore_global', '.husky',
	'.github', '.envrc', '.git-hooks', '.githooks', '.pre-commit-config.yaml', '.mailmap']

// workspace_segment_key folds the tricks that make a different spelling name
// the same protected entry on some filesystems: case, trailing dots/spaces
// (Windows), NTFS alternate data streams and 8.3 short names.
fn workspace_segment_key(segment string) string {
	mut key := segment.to_lower()
	if idx := key.index(':') {
		key = key[..idx]
	}
	key = key.trim_right('. ')
	return key
}

fn workspace_segment_is_short_name_of(key string, name string) bool {
	// "GIT~1" style 8.3 aliases for ".git", ".github", ".gitattributes" ...
	if !key.contains('~') {
		return false
	}
	stem := name.trim_left('.').replace('-', '')
	prefix := key.all_before('~')
	return prefix.len > 0 && stem.starts_with(prefix) && prefix.len <= 6
}

fn workspace_segment_is_protected(segment string) bool {
	key := workspace_segment_key(segment)
	for name in workspace_protected_directory_names {
		if key == name || workspace_segment_is_short_name_of(key, name) {
			return true
		}
	}
	return false
}

fn workspace_segment_is_sensitive(segment string) bool {
	key := workspace_segment_key(segment)
	for name in workspace_sensitive_names {
		if key == name || workspace_segment_is_short_name_of(key, name) {
			return true
		}
	}
	return false
}

// workspace_relative_path_is_sensitive reports whether any component of a
// workspace-relative path is a sensitive (hook/CI/config) name.
fn workspace_relative_path_is_sensitive(relative_path string) bool {
	for segment in relative_path.replace('\\', '/').split('/') {
		if workspace_segment_is_sensitive(segment) {
			return true
		}
	}
	return false
}
