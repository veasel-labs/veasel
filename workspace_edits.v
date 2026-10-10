module main

import arrays.diff
import crypto.sha256
import encoding.hex
import encoding.utf8
import os

$if windows {
	#include <windows.h>

	fn C.ReplaceFileW(replaced_file &u16, replacement_file &u16, backup_file &u16, replace_flags u32,
		exclude voidptr, reserved voidptr) i32
}

const max_workspace_edit_bytes = 512_000
const max_workspace_edit_request_bytes = max_workspace_edit_bytes * 6 + 4_096
const max_pending_workspace_edits = 20

pub struct WorkspaceEditProposal {
pub:
	id         string
	session_id string
	path       string
	diff       string
	status     string
	created_at string
	updated_at string
}

pub struct WorkspaceEditSummary {
pub:
	id         string
	path       string
	status     string
	created_at string
	updated_at string
}

struct WorkspaceEditDraft {
	path          string
	expected_hash string
	content       string
	diff          string
	create_file   bool
}

struct StoredWorkspaceEdit {
	id            string
	session_id    string
	path          string
	expected_hash string
	content       string
	diff          string
	create_file   bool
	status        string
}

fn prepare_workspace_edit(root string, relative_path string, content string) !WorkspaceEditDraft {
	if content.len > max_workspace_edit_bytes {
		return error('proposed file exceeds the ${max_workspace_edit_bytes} byte limit')
	}
	content_bytes := content.bytes()
	if content_bytes.contains(0) || (content_bytes.len > 0 && !utf8.validate(&content_bytes[0], content_bytes.len)) {
		return error('proposed file must contain UTF-8 text without NUL bytes')
	}
	if workspace_has_hidden_controls(content) {
		return error('proposed file contains control characters that cannot be safely reviewed in the TUI')
	}
	path := resolve_workspace_edit_target(root, relative_path)!
	create_file := !os.exists(path)
	old_content := if create_file { '' } else { read_workspace_text_file(path)! }
	if workspace_has_hidden_controls(old_content) {
		return error('workspace file contains control characters that cannot be safely reviewed in the TUI')
	}
	if old_content == content {
		return error('proposed file has no changes')
	}
	old_lines := old_content.split_into_lines()
	new_lines := content.split_into_lines()
	if old_lines.len > 2_000 || new_lines.len > 2_000 {
		return error('proposed file exceeds the 2000-line diff limit')
	}
	mut changes := diff.diff[string](old_lines, new_lines)
	mut patch := changes.generate_patch(unified: 3, block_header: true)
	line_ending_diff := workspace_line_ending_diff(old_content, content)
	if line_ending_diff.len > 0 {
		patch += '\n${line_ending_diff}'
	}
	return WorkspaceEditDraft{
		path:          relative_path.replace('\\', '/')
		expected_hash: workspace_content_hash(old_content)
		content:       content
		diff:          '--- ${relative_path}\n+++ ${relative_path}\n${patch}'
		create_file:   create_file
	}
}

fn workspace_line_ending_diff(old_content string, new_content string) string {
	old_endings := workspace_line_endings(old_content)
	new_endings := workspace_line_endings(new_content)
	if old_endings == new_endings {
		return ''
	}
	mut changes := ['Line ending changes:']
	ending_count := if old_endings.len > new_endings.len {
		old_endings.len
	} else {
		new_endings.len
	}
	for index in 0 .. ending_count {
		old_ending := if index < old_endings.len { old_endings[index] } else { 'no line' }
		new_ending := if index < new_endings.len { new_endings[index] } else { 'no line' }
		if old_ending != new_ending {
			changes << '- line ${index + 1}: ${old_ending}'
			changes << '+ line ${index + 1}: ${new_ending}'
		}
	}
	return changes.join('\n')
}

fn workspace_line_endings(content string) []string {
	mut endings := []string{}
	mut line_start := 0
	mut index := 0
	for index < content.len {
		if content[index] == `\r` {
			if index + 1 < content.len && content[index + 1] == `\n` {
				endings << 'CRLF'
				index += 2
			} else {
				endings << 'CR'
				index++
			}
			line_start = index
		} else if content[index] == `\n` {
			endings << 'LF'
			index++
			line_start = index
		} else {
			index++
		}
	}
	if line_start < content.len {
		endings << 'no line ending'
	}
	return endings
}

fn workspace_has_hidden_controls(content string) bool {
	for character in content.runes() {
		if utf8.is_control(character) && character !in [`\n`, `\r`, `\t`] {
			return true
		}
	}
	return false
}

fn resolve_workspace_edit_target(root string, relative_path string) !string {
	if relative_path.len == 0 || relative_path.len > 4_096 || os.is_abs_path(relative_path)
		|| relative_path.contains('\x00') {
		return error('workspace edit path must be a non-empty relative path')
	}
	if workspace_has_hidden_controls(relative_path) {
		return error('workspace edit path contains control characters')
	}
	segments := relative_path.replace('\\', '/').split('/')
	for segment in segments {
		if segment in ['', '.', '..'] {
			return error('workspace edit path contains an invalid segment')
		}
		if segment.to_lower() in ['.git', '.hg', '.svn', 'node_modules', 'vendor'] {
			return error('workspace edit path targets a protected directory')
		}
	}
	canonical_root := canonical_workspace_root(root)!
	joined := os.join_path(canonical_root, relative_path.replace('\\', os.path_separator))
	if !path_is_within(canonical_root, joined) {
		return error('workspace edit path escapes the selected root')
	}
	mut parent := canonical_root
	for segment in segments[..segments.len - 1] {
		parent = os.join_path(parent, segment)
		if os.is_link(parent) {
			return error('workspace edit path must not traverse symbolic links')
		}
		if !os.is_dir(parent) {
			return error('workspace edit parent directory does not exist')
		}
		parent = os.real_path(parent)
		if !path_is_within(canonical_root, parent) {
			return error('workspace edit parent directory escapes the selected root')
		}
	}
	if os.is_link(joined) {
		return error('workspace edit path must not be a symbolic link')
	}
	if os.exists(joined) {
		if !os.is_file(joined) || os.file_size(joined) > max_workspace_edit_bytes {
			return error('workspace edit target must be a bounded regular file')
		}
		return os.real_path(joined)
	}
	return joined
}

fn workspace_content_hash(content string) string {
	return hex.encode(sha256.sum256(content.bytes()), hex.EncodeParams{})
}

fn apply_workspace_edit(root string, edit StoredWorkspaceEdit) ! {
	path := resolve_workspace_edit_target(root, edit.path)!
	create_file := !os.exists(path)
	if create_file != edit.create_file {
		return error('workspace edit target changed after review')
	}
	current := if create_file { '' } else { read_workspace_text_file(path)! }
	if workspace_content_hash(current) != edit.expected_hash {
		return error('workspace file changed after review')
	}
	mut mode := -1
	$if !windows {
		if !create_file {
			mode = int(os.stat(path)!.mode & 0o777)
		}
	}
	parent := os.dir(path)
	temporary := os.join_path(parent, '.veasel-edit-${edit.id}.tmp')
	backup := os.join_path(parent, '.veasel-edit-${edit.id}.bak')
	if os.exists(temporary) {
		return error('temporary workspace edit file already exists')
	}
	if os.exists(backup) {
		return error('workspace edit backup already exists; inspect it before retrying')
	}
	os.write_file(temporary, edit.content) or {
		return error('unable to write the reviewed workspace edit')
	}
	$if !windows {
		if mode >= 0 {
			os.chmod(temporary, mode) or {
				os.rm(temporary) or {}
				return error('unable to preserve workspace file permissions')
			}
		}
	}
	$if windows {
		if create_file {
			os.rename(temporary, path) or {
				os.rm(temporary) or {}
				return error('unable to create the reviewed workspace file')
			}
		} else if C.ReplaceFileW(path.to_wide(), temporary.to_wide(), backup.to_wide(), 0,
			unsafe { nil }, unsafe { nil }) == 0 {
			if !os.exists(path) && os.exists(backup) {
				os.rename(backup, path) or {
					eprintln('veasel: unable to restore workspace edit backup ${backup}: ${err.msg()}')
				}
			}
			return error('unable to atomically replace the reviewed workspace file; inspect the target, .veasel-edit-${edit.id}.tmp proposed-content recovery file, and .veasel-edit-${edit.id}.bak original-file recovery file')
		} else {
			os.rm(backup) or {
				eprintln('veasel: workspace edit applied; unable to remove original-file backup ${backup}: ${err.msg()}')
			}
		}
	} $else {
		os.rename(temporary, path) or {
			os.rm(temporary) or {}
			return error('unable to replace the reviewed workspace file')
		}
	}
}

fn recover_interrupted_workspace_edit(root string, id string, relative_path string) {
	path := resolve_workspace_edit_target(root, relative_path) or {
		eprintln('veasel: unable to inspect workspace edit recovery target ${relative_path}: ${err.msg()}')
		return
	}
	backup := os.join_path(os.dir(path), '.veasel-edit-${id}.bak')
	if !os.exists(path) && os.exists(backup) && !os.is_link(backup) {
		os.rename(backup, path) or {
			eprintln('veasel: unable to restore interrupted workspace edit backup for ${relative_path}: ${err.msg()}')
		}
	}
}
