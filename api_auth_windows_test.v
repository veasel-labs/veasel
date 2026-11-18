module main

import os
import uuid

// icacls-based ACL tests; they run only on a Windows runner. The pure
// SDDL parser/allowlist tests are in api_auth_acl_test.v and run everywhere.

fn windows_auth_test_root() string {
	root := os.join_path(os.temp_dir(), 'veasel-winacl-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	return root
}

fn test_windows_token_file_and_directory_pass_the_allowlist() {
	$if windows {
		root := windows_auth_test_root()
		defer {
			os.rmdir_all(root) or {}
		}
		data := os.join_path(root, 'data')
		token := load_or_create_api_token(data) or { panic(err) }
		assert is_valid_generated_token(token)
		path := api_token_path(data)
		me := current_windows_principal() or { panic(err) }
		for target in [path, data] {
			trustees := windows_acl_trustees(target) or { panic(err) }
			assert trustees.len > 0
			assert first_disallowed_trustee(trustees, me.sid, me.is_local()) == none, '${target}: ${trustees}'
			windows_acl_is_private(target) or { panic(err) }
		}
		assert load_or_create_api_token(data) or { panic(err) } == token
		assert read_token_file(path) or { panic(err) } == token
	}
}

fn test_windows_widened_token_acl_is_refused() {
	$if windows {
		root := windows_auth_test_root()
		defer {
			os.rmdir_all(root) or {}
		}
		data := os.join_path(root, 'data')
		load_or_create_api_token(data) or { panic(err) }
		path := api_token_path(data)
		// Everyone, BUILTIN\Users, Authenticated Users.
		for sid in ['S-1-1-0', 'S-1-5-32-545', 'S-1-5-11'] {
			grant := os.exec(['icacls', path, '/grant', '*${sid}:R'])
			assert grant.exit_code == 0, grant.output
			if _ := verify_private_file(path) {
				assert false, 'a token readable by ${sid} must be refused'
			}
			if _ := read_token_file(path) {
				assert false, 'read must fail closed for ${sid}'
			}
			if _ := load_or_create_api_token(data) {
				assert false, 'startup must fail closed for ${sid}'
			}
			assert (discover_api_token(data) or { '' }) == ''
			restrict_windows_acl(path, false) or { panic(err) }
			verify_private_file(path) or { panic(err) }
		}
		// A second local principal is not created here: that needs an
		// administrator account change on the runner. The allowlist unit test
		// above covers an arbitrary foreign user SID.
	}
}

fn test_windows_widened_data_directory_is_restricted_again() {
	$if windows {
		root := windows_auth_test_root()
		defer {
			os.rmdir_all(root) or {}
		}
		data := os.join_path(root, 'data')
		os.mkdir_all(data) or { panic(err) }
		grant := os.exec(['icacls', data, '/grant', '*S-1-1-0:(OI)(CI)R'])
		assert grant.exit_code == 0, grant.output
		if _ := windows_acl_is_private(data) {
			assert false, 'directory should be broad before ensure_private_directory'
		}
		ensure_private_directory(data) or { panic(err) }
		windows_acl_is_private(data) or { panic(err) }
	}
}
