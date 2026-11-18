module main

import os
import uuid

// Native Windows checks for the token ACL. On other platforms every test
// body is compiled out (POSIX modes are covered by api_auth_test.v).

fn windows_auth_test_root() string {
	root := os.join_path(os.temp_dir(), 'veasel-winacl-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	return root
}

fn test_windows_parse_icacls_output_extracts_every_principal() {
	$if windows {
		check_windows_icacls_parser()
	}
}

fn check_windows_icacls_parser() {
	$if windows {
		output := 'C:\\data\\api-token DESKTOP\\ada:(I)(F)\r\n                    Everyone:(I)(R)\r\n                    BUILTIN\\Users:(I)(RX)\r\n                    NT AUTHORITY\\Authenticated Users:(I)(M)\r\n\r\nSuccessfully processed 1 files; Failed processing 0 files\r\n'
		assert parse_icacls_principals('C:\\data\\api-token', output) == [
			'DESKTOP\\ada',
			'Everyone',
			'BUILTIN\\Users',
			'NT AUTHORITY\\Authenticated Users',
		]
	}
}

fn test_windows_token_file_and_directory_are_private_to_the_current_user() {
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
		for principal in windows_acl_principals(path) or { panic(err) } {
			assert principal.to_lower() == me.name.to_lower() || principal == me.sid
			assert principal !in ['Everyone', 'BUILTIN\\Users', 'NT AUTHORITY\\Authenticated Users']
		}
		for principal in windows_acl_principals(data) or { panic(err) } {
			assert principal.to_lower() == me.name.to_lower() || principal == me.sid
		}
		// Reuse across restarts keeps the same value.
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
		for sid in ['S-1-1-0', 'S-1-5-32-545', 'S-1-5-11'] { // Everyone, Users, Authenticated Users
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
