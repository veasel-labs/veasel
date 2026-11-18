module main

import os
import uuid

// Real OS keychain round trip. Opt-in only: it writes to the user's actual
// credential store, so it runs solely when VEASEL_NATIVE_KEYCHAIN_TEST=1
// (use a private D-Bus session on Linux; CI macOS/Windows runners set it).
fn test_native_keychain_round_trip() {
	if os.getenv('VEASEL_NATIVE_KEYCHAIN_TEST') != '1' || os.getenv('VEASEL_NATIVE_KEYCHAIN_TEST_UNREACHABLE') == '1' {
		return
	}
	mut backend := native_secret_backend()
	account := 'veasel-native-test/${uuid.new_v4().str()}'
	secret := 'synthetic-native-secret-${uuid.new_v4().str()}'
	defer { backend.delete(account) or {} }
	assert backend.get(account)! == ''
	backend.set(account, secret)!
	assert backend.get(account)! == secret
	backend.set(account, '${secret}-v2')!
	assert backend.get(account)! == '${secret}-v2'
	backend.delete(account)!
	assert backend.get(account)! == ''
	backend.delete(account)! // deleting a missing entry is not an error
}

// End-to-end migration through the real native backend (same opt-in gate).
fn test_native_keychain_migrates_legacy_settings() {
	if os.getenv('VEASEL_NATIVE_KEYCHAIN_TEST') != '1' || os.getenv('VEASEL_NATIVE_KEYCHAIN_TEST_UNREACHABLE') == '1' {
		return
	}
	root := os.join_path(os.temp_dir(), 'veasel-native-${uuid.new_v4().str()}')
	os.mkdir_all(root)!
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'model-settings.json')
	secret := 'synthetic-native-legacy-${uuid.new_v4().str()}'
	os.write_file(path, '{"active_provider":"openai","profiles":{"openai":{"model":"gpt-5","base_url":"https://api.openai.com/v1","api_key":"${secret}","max_output_tokens":0}}}')!
	mut state := new_model_settings_state_with(path, 'keychain', native_secret_backend())
	defer { state.backend.delete(model_secret_account(state.scope, 'openai')) or {} }
	assert state.view().secret_store_error == ''
	assert !os.read_file(path)!.contains(secret)
	assert !os.read_file('${path}.pre-keychain')!.contains(secret)
	mut reloaded := new_model_settings_state_with(path, 'keychain', native_secret_backend())
	assert reloaded.api_key_for('openai')! == secret
}

// With no reachable keyring the native backend must fail closed (run with a
// bogus DBUS_SESSION_BUS_ADDRESS to exercise it).
fn test_native_unreachable_keychain_fails_closed() {
	if os.getenv('VEASEL_NATIVE_KEYCHAIN_TEST_UNREACHABLE') != '1' {
		return
	}
	root := os.join_path(os.temp_dir(), 'veasel-native-${uuid.new_v4().str()}')
	os.mkdir_all(root)!
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'model-settings.json')
	mut state := new_model_settings_state_with(path, 'keychain', native_secret_backend())
	state.update(ModelSettingsInput{
		provider: 'openai'
		model:    'gpt-5'
		base_url: 'https://api.openai.com/v1'
		api_key:  'synthetic-unreachable-key'
	}) or {
		assert err.msg().contains('VEASEL_SECRET_STORE=file')
		assert !os.exists(path)
		return
	}
	assert false
}
