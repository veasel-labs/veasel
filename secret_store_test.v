module main

import os
import uuid
import json2

const legacy_key_a = 'synthetic-legacy-key-AAAA-1111'
const legacy_key_b = 'synthetic-legacy-key-BBBB-2222'

// FakeSecretBackend is an in-memory stand-in for the OS keychain. Tests never
// touch a real keyring.
@[heap]
struct FakeSecretBackend {
mut:
	entries        map[string]string
	locked         bool
	set_calls      int
	fail_set_after int = -1
	corrupt_reads  bool
}

fn (mut b FakeSecretBackend) get(account string) !string {
	if b.locked {
		return error('keychain is locked')
	}
	if b.corrupt_reads {
		return 'not-the-stored-value'
	}
	return b.entries[account] or { '' }
}

fn (mut b FakeSecretBackend) set(account string, secret string) ! {
	if b.locked {
		return error('keychain is locked')
	}
	if b.fail_set_after >= 0 && b.set_calls >= b.fail_set_after {
		return error('keychain write failed')
	}
	b.set_calls++
	b.entries[account] = secret
}

fn (mut b FakeSecretBackend) delete(account string) ! {
	if b.locked {
		return error('keychain is locked')
	}
	b.entries.delete(account)
}

fn secret_test_dir() string {
	root := os.join_path(os.temp_dir(), 'veasel-secret-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	return root
}

fn write_legacy_settings(path string) {
	os.write_file(path, '{"active_provider":"openai","profiles":{"openai":{"model":"gpt-5","base_url":"https://api.openai.com/v1","api_key":"${legacy_key_a}","max_output_tokens":0},"anthropic":{"model":"claude","base_url":"https://api.anthropic.com/v1","api_key":"${legacy_key_b}","max_output_tokens":0}}}') or {
		panic(err)
	}
}

fn data_dir_contains(root string, needle string) bool {
	for entry in os.walk_ext(root, '') {
		content := os.read_file(entry) or { continue }
		if content.contains(needle) {
			return true
		}
	}
	return false
}

fn test_legacy_plaintext_keys_migrate_into_keychain_and_leave_json() {
	root := secret_test_dir()
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'model-settings.json')
	write_legacy_settings(path)
	mut fake := &FakeSecretBackend{}
	mut state := new_model_settings_state_with(path, 'keychain', fake)
	view := state.view()
	assert view.secret_store == 'keychain'
	assert view.secret_store_error == ''
	assert view.profiles['openai'].api_key_saved
	assert view.profiles['anthropic'].api_key_saved
	assert state.api_key_for('openai')! == legacy_key_a
	assert fake.entries.values().contains(legacy_key_a)
	assert fake.entries.values().contains(legacy_key_b)
	// The recoverable backup and the live JSON carry no secret at all.
	assert !data_dir_contains(root, legacy_key_a)
	assert !data_dir_contains(root, legacy_key_b)
	assert os.exists('${path}.pre-keychain')
	assert !json2.encode(view).contains(legacy_key_a)
}

fn test_migration_is_idempotent_and_survives_restart() {
	root := secret_test_dir()
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'model-settings.json')
	write_legacy_settings(path)
	mut fake := &FakeSecretBackend{}
	_ = new_model_settings_state_with(path, 'keychain', fake)
	sets := fake.set_calls
	before := os.read_file(path)!
	mut again := new_model_settings_state_with(path, 'keychain', fake)
	assert fake.set_calls == sets
	assert os.read_file(path)! == before
	assert again.api_key_for('anthropic')! == legacy_key_b
	assert again.view().profiles['anthropic'].api_key_saved
}

fn test_interrupted_migration_keeps_plaintext_until_keychain_verified() {
	root := secret_test_dir()
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'model-settings.json')
	write_legacy_settings(path)
	original := os.read_file(path)!
	// Keychain write fails on the second profile.
	mut fake := &FakeSecretBackend{
		fail_set_after: 1
	}
	mut state := new_model_settings_state_with(path, 'keychain', fake)
	assert os.read_file(path)! == original // never deleted before verified
	assert state.view().secret_store_error != ''
	assert !json2.encode(state.view()).contains(legacy_key_a)
	state.update(ModelSettingsInput{ provider: 'openai', model: 'gpt-5', base_url: 'https://api.openai.com/v1' }) or {
		assert err.msg().contains('VEASEL_SECRET_STORE=file')
		assert os.read_file(path)! == original // update cannot drop pending plaintext
		// Recovery: keychain healthy again, restart finishes the migration.
		mut healthy := &FakeSecretBackend{}
		mut recovered := new_model_settings_state_with(path, 'keychain', healthy)
		assert recovered.view().secret_store_error == ''
		assert !data_dir_contains(root, legacy_key_a)
		assert !data_dir_contains(root, legacy_key_b)
		assert recovered.api_key_for('openai')! == legacy_key_a
		return
	}
	assert false
}

fn test_crash_after_keychain_write_before_json_rewrite_recovers() {
	root := secret_test_dir()
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'model-settings.json')
	write_legacy_settings(path)
	// A previous run stored both keys, then died before rewriting the JSON.
	mut fake := &FakeSecretBackend{}
	_ = new_model_settings_state_with(path, 'keychain', fake)
	write_legacy_settings(path)
	mut state := new_model_settings_state_with(path, 'keychain', fake)
	assert state.view().secret_store_error == ''
	assert !data_dir_contains(root, legacy_key_a)
	assert state.api_key_for('openai')! == legacy_key_a
}

fn test_unverifiable_keychain_write_aborts_migration() {
	root := secret_test_dir()
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'model-settings.json')
	write_legacy_settings(path)
	original := os.read_file(path)!
	mut fake := &FakeSecretBackend{
		corrupt_reads: true
	}
	mut state := new_model_settings_state_with(path, 'keychain', fake)
	assert os.read_file(path)! == original
	assert state.view().secret_store_error != ''
}

fn test_locked_keychain_fails_closed_with_actionable_error() {
	root := secret_test_dir()
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'model-settings.json')
	write_legacy_settings(path)
	original := os.read_file(path)!
	mut fake := &FakeSecretBackend{
		locked: true
	}
	mut state := new_model_settings_state_with(path, 'keychain', fake)
	view := state.view()
	assert view.secret_store == 'keychain'
	assert view.secret_store_error.contains('VEASEL_SECRET_STORE=file')
	assert os.read_file(path)! == original
	state.api_key_for('openai') or {
		assert err.msg().contains('VEASEL_SECRET_STORE=file')
		assert !err.msg().contains(legacy_key_a)
		return
	}
	assert false
}

fn test_locked_keychain_never_writes_new_key_to_disk() {
	root := secret_test_dir()
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'model-settings.json')
	mut fake := &FakeSecretBackend{
		locked: true
	}
	mut state := new_model_settings_state_with(path, 'keychain', fake)
	state.update(ModelSettingsInput{
		provider: 'openai'
		model:    'gpt-5'
		base_url: 'https://api.openai.com/v1'
		api_key:  'synthetic-new-key-CCCC'
	}) or {
		assert err.msg().contains('VEASEL_SECRET_STORE=file')
		assert !os.exists(path) || !data_dir_contains(root, 'synthetic-new-key-CCCC')
		assert !data_dir_contains(root, 'synthetic-new-key-CCCC')
		return
	}
	assert false
}

fn test_keychain_update_keeps_key_out_of_json_and_supports_clear() {
	root := secret_test_dir()
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'model-settings.json')
	mut fake := &FakeSecretBackend{}
	mut state := new_model_settings_state_with(path, 'keychain', fake)
	state.update(ModelSettingsInput{
		provider: 'openai'
		model:    'gpt-5'
		base_url: 'https://api.openai.com/v1'
		api_key:  'synthetic-new-key-DDDD'
	})!
	assert !data_dir_contains(root, 'synthetic-new-key-DDDD')
	assert fake.entries.values().contains('synthetic-new-key-DDDD')
	mut reloaded := new_model_settings_state_with(path, 'keychain', fake)
	assert reloaded.api_key_for('openai')! == 'synthetic-new-key-DDDD'
	assert reloaded.view().profiles['openai'].api_key_saved
	// Blank key preserves; endpoint change drops key and deletes the entry.
	reloaded.update(ModelSettingsInput{ provider: 'openai', model: 'gpt-5-mini', base_url: 'https://api.openai.com/v1' })!
	assert reloaded.api_key_for('openai')! == 'synthetic-new-key-DDDD'
	reloaded.update(ModelSettingsInput{ provider: 'openai', model: 'gpt-5-mini', base_url: 'https://example.invalid/v1' })!
	assert reloaded.api_key_for('openai')! == ''
	assert fake.entries.len == 0
	assert !reloaded.view().profiles['openai'].api_key_saved
}

fn test_failed_json_write_rolls_back_keychain_entry() {
	root := secret_test_dir()
	defer { os.rmdir_all(root) or {} }
	// The settings directory is a regular file, so persisting must fail.
	blocker := os.join_path(root, 'blocker')
	os.write_file(blocker, 'x')!
	path := os.join_path(blocker, 'model-settings.json')
	mut fake := &FakeSecretBackend{}
	mut state := new_model_settings_state_with(path, 'keychain', fake)
	state.update(ModelSettingsInput{
		provider: 'openai'
		model:    'gpt-5'
		base_url: 'https://api.openai.com/v1'
		api_key:  'synthetic-new-key-EEEE'
	}) or {
		assert fake.entries.len == 0
		return
	}
	assert false
}

fn test_file_mode_is_explicit_opt_in_and_reported_truthfully() {
	root := secret_test_dir()
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'model-settings.json')
	mut fake := &FakeSecretBackend{
		locked: true
	}
	mut state := new_model_settings_state_with(path, 'file', fake)
	state.update(ModelSettingsInput{
		provider: 'openai'
		model:    'gpt-5'
		base_url: 'https://api.openai.com/v1'
		api_key:  'synthetic-file-key-FFFF'
	})!
	assert state.view().secret_store == 'file'
	assert os.read_file(path)!.contains('synthetic-file-key-FFFF')
	$if !windows {
		assert int(os.inode(path).bitmask()) & 0o777 == 0o600
	}
	assert fake.set_calls == 0
	assert !json2.encode(state.view()).contains('synthetic-file-key-FFFF')
}

fn test_rollback_to_file_mode_restores_keys_and_removes_keychain_entries() {
	root := secret_test_dir()
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'model-settings.json')
	write_legacy_settings(path)
	mut fake := &FakeSecretBackend{}
	_ = new_model_settings_state_with(path, 'keychain', fake)
	assert !data_dir_contains(root, legacy_key_a)
	mut back := new_model_settings_state_with(path, 'file', fake)
	assert back.view().secret_store == 'file'
	assert back.view().secret_store_error == ''
	assert back.api_key_for('openai')! == legacy_key_a
	assert os.read_file(path)!.contains(legacy_key_a)
	assert fake.entries.len == 0
	// Idempotent.
	mut again := new_model_settings_state_with(path, 'file', fake)
	assert again.api_key_for('anthropic')! == legacy_key_b
}

fn test_rollback_with_locked_keychain_keeps_references_and_reports() {
	root := secret_test_dir()
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'model-settings.json')
	write_legacy_settings(path)
	mut fake := &FakeSecretBackend{}
	_ = new_model_settings_state_with(path, 'keychain', fake)
	fake.locked = true
	mut back := new_model_settings_state_with(path, 'file', fake)
	assert back.view().secret_store_error != ''
	assert back.view().profiles['openai'].api_key_saved
	assert !data_dir_contains(root, legacy_key_a)
}

fn test_secret_store_mode_environment_parsing() {
	assert parse_secret_store_mode('') == 'keychain'
	assert parse_secret_store_mode('keychain') == 'keychain'
	assert parse_secret_store_mode('FILE') == 'file'
	assert parse_secret_store_mode(' file ') == 'file'
	assert parse_secret_store_mode('plaintext') == 'invalid'
}

// Recording command runner: proves secrets travel on stdin only, never argv.
struct RecordedCommand {
	exe   string
	args  []string
	stdin string
}

@[heap]
struct RecordingRunner {
mut:
	commands []RecordedCommand
	reply    SecretCommandResult
}

fn (mut r RecordingRunner) run(exe string, args []string, stdin string) !SecretCommandResult {
	r.commands << RecordedCommand{exe, args.clone(), stdin}
	return r.reply
}

fn test_secret_tool_backend_passes_secret_on_stdin_only() {
	mut runner := &RecordingRunner{}
	mut backend := SecretToolBackend{
		runner: fn [mut runner] (exe string, args []string, stdin string) !SecretCommandResult {
			return runner.run(exe, args, stdin)!
		}
	}
	backend.set('model-api-key/abc/openai', 'synthetic-linux-secret') or { panic(err) }
	assert runner.commands.len == 1
	assert runner.commands[0].stdin == 'synthetic-linux-secret'
	assert !runner.commands[0].args.join(' ').contains('synthetic-linux-secret')
	assert runner.commands[0].args[0] == 'store'
	assert 'model-api-key/abc/openai' in runner.commands[0].args
}

fn test_secret_tool_lookup_distinguishes_missing_from_failure() {
	mut missing := SecretToolBackend{
		runner: fn (exe string, args []string, stdin string) !SecretCommandResult {
			return SecretCommandResult{
				code: 1
			}
		}
	}
	assert missing.get('a')! == ''
	mut broken := SecretToolBackend{
		runner: fn (exe string, args []string, stdin string) !SecretCommandResult {
			return SecretCommandResult{
				code:   1
				stderr: 'Cannot autolaunch D-Bus without X11 $DISPLAY'
			}
		}
	}
	broken.get('a') or {
		assert err.msg().contains('VEASEL_SECRET_STORE=file')
		return
	}
	assert false
}

fn test_macos_backend_uses_stdin_script_with_hex_secret() {
	mut runner := &RecordingRunner{}
	mut backend := MacKeychainBackend{
		runner: fn [mut runner] (exe string, args []string, stdin string) !SecretCommandResult {
			return runner.run(exe, args, stdin)!
		}
	}
	backend.set('model-api-key/abc/openai', 'synthetic-mac-secret') or { panic(err) }
	assert runner.commands.len == 1
	assert runner.commands[0].args == ['-i']
	assert !runner.commands[0].args.join(' ').contains('synthetic-mac-secret')
	assert !runner.commands[0].stdin.contains('synthetic-mac-secret') // hex encoded
	assert runner.commands[0].stdin.contains('add-generic-password')
	assert runner.commands[0].stdin.contains('-U')
}

fn test_secret_account_scope_is_stable_and_directory_specific() {
	a := secret_account_scope('/tmp/veasel-a/model-settings.json')
	assert a == secret_account_scope('/tmp/veasel-a/model-settings.json')
	assert a != secret_account_scope('/tmp/veasel-b/model-settings.json')
	assert a.len == 16
}

fn test_command_runner_delivers_stdin_and_enforces_timeout() {
	$if windows {
		return
	}
	res := run_secret_command('/bin/cat', []string{}, 'synthetic-roundtrip', 5000)!
	assert res.code == 0
	assert res.stdout == 'synthetic-roundtrip'
	run_secret_command('/bin/sleep', ['30'], '', 300) or {
		assert err.msg().contains('timed out')
		return
	}
	assert false
}
