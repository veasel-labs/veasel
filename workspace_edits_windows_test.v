module main

import os
import uuid

fn test_windows_workspace_edit_replaces_existing_file() {
	$if windows {
		root := os.join_path(os.temp_dir(), 'veasel-windows-edit-${uuid.new_v4().str()}')
		os.mkdir_all(root) or { panic(err) }
		defer { os.rmdir_all(root) or {} }
		path := os.join_path(root, 'existing.v')
		os.write_file(path, 'before\n') or { panic(err) }
		edit := StoredWorkspaceEdit{
			id:            uuid.new_v4().str()
			path:          'existing.v'
			expected_hash: workspace_content_hash('before\n')
			content:       'after\n'
			create_file:   false
			status:        'applying'
		}
		apply_workspace_edit(root, edit) or { panic(err) }
		assert os.read_file(path) or { panic(err) } == 'after\n'
		assert !os.exists(os.join_path(root, '.veasel-edit-${edit.id}.bak'))
		assert !os.exists(os.join_path(root, '.veasel-edit-${edit.id}.tmp'))
	}
}
