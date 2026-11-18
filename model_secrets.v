module main

import json2
import os
import time

// Provider-key custody for ModelSettingsState (issue #690).
//
// Invariants:
//   * a key is never deleted from the plaintext JSON before the same value was
//     written to the keychain AND read back identically;
//   * a locked/missing keychain never degrades to plaintext writes: it yields
//     an actionable error (opt-in escape hatch: VEASEL_SECRET_STORE=file);
//   * the redacted backup written at migration contains no secret.

const secret_retry_interval_ms = 5_000

const migration_restore_note = 'Provider API keys were moved to the OS keychain; this backup holds no secrets. Roll back with VEASEL_SECRET_STORE=file and a restart (keys are copied back from the keychain into model-settings.json).'

// sync_secrets reconciles disk and keychain for the configured mode. Callers
// hold the state lock (or are the constructor).
fn (mut state ModelSettingsState) sync_secrets() {
	state.secret_error = ''
	state.unavailable = map[string]bool{}
	state.last_secret_attempt = time.now().unix_milli()
	if state.path == '' {
		return
	}
	if state.mode == 'keychain' {
		state.sync_keychain_mode()
	} else {
		state.sync_file_mode()
	}
}

// retry_secret_sync re-attempts a failed sync (for example after the user
// unlocks the keyring) at most every few seconds. State is re-read from disk,
// which is the source of truth.
fn (mut state ModelSettingsState) retry_secret_sync() {
	if state.secret_error == '' || state.path == '' {
		return
	}
	if time.now().unix_milli() - state.last_secret_attempt < secret_retry_interval_ms {
		return
	}
	state.load_from_disk()
	state.sync_secrets()
}

fn (mut state ModelSettingsState) fail_secret_sync(detail string) {
	state.secret_error = with_keychain_hint(detail)
}

fn (mut state ModelSettingsState) keychain_write_verified(account string, key string) ! {
	state.backend.set(account, key) or { return error(with_keychain_hint(err.msg())) }
	stored := state.backend.get(account) or { return error(with_keychain_hint(err.msg())) }
	if stored != key {
		return error(with_keychain_hint('keychain read-back did not match the value written'))
	}
}

fn profile_with_secret(profile ModelProfile, key string, in_keychain bool) ModelProfile {
	return ModelProfile{
		...profile
		api_key:         key
		key_in_keychain: in_keychain
	}
}

fn (mut state ModelSettingsState) sync_keychain_mode() {
	if state.plaintext_on_disk.len > 0 {
		state.migrate_plaintext_keys()
		if state.plaintext_on_disk.len > 0 {
			return
		}
	}
	mut providers := []string{}
	for provider, profile in state.settings.profiles {
		if profile.key_in_keychain && profile.api_key.len == 0 {
			providers << provider
		}
	}
	providers.sort()
	for provider in providers {
		profile := state.settings.profiles[provider]
		stored := state.backend.get(model_secret_account(state.scope, provider)) or {
			state.unavailable[provider] = true
			state.fail_secret_sync(err.msg())
			continue
		}
		if stored.len == 0 {
			state.unavailable[provider] = true
			state.fail_secret_sync('the keychain entry for ${provider} is missing; enter the API key again')
			continue
		}
		state.settings.profiles[provider] = profile_with_secret(profile, stored, true)
	}
}

// migrate_plaintext_keys moves legacy plaintext keys into the keychain.
// Order: redacted backup -> keychain write + verified read-back for EVERY key
// -> rewrite the JSON without secrets. Any failure leaves the JSON untouched
// and the keys unusable until the keychain works (or file mode is chosen).
fn (mut state ModelSettingsState) migrate_plaintext_keys() {
	mut providers := state.plaintext_on_disk.keys()
	providers.sort()
	mut secrets := map[string]string{}
	for provider in providers {
		secrets[provider] = (state.settings.profiles[provider] or { ModelProfile{} }).api_key
	}
	state.write_redacted_backup(providers)
	mut failure := ''
	for provider in providers {
		account := model_secret_account(state.scope, provider)
		state.keychain_write_verified(account, secrets[provider]) or {
			failure = err.msg()
			break
		}
	}
	if failure == '' {
		mut migrated := state.settings.profiles.clone()
		for provider in providers {
			migrated[provider] = profile_with_secret(migrated[provider], secrets[provider],
				true)
		}
		updated := PersistedModelSettings{
			active_provider: state.settings.active_provider
			profiles:        migrated
		}
		state.persist(updated) or { failure = 'could not rewrite the settings file: ${err.msg()}' }
		if failure == '' {
			state.settings = updated
			state.plaintext_on_disk = map[string]bool{}
			return
		}
	}
	// Fail closed: keep the file as-is, do not use the plaintext keys.
	for provider in providers {
		state.settings.profiles[provider] = profile_with_secret(state.settings.profiles[provider],
			'', false)
		state.unavailable[provider] = true
	}
	state.fail_secret_sync(failure)
}

// write_redacted_backup stores a one-time copy of the legacy settings with
// every key removed (never an extra plaintext secret).
fn (state &ModelSettingsState) write_redacted_backup(providers []string) {
	backup_path := '${state.path}.pre-keychain'
	if state.path == '' || os.exists(backup_path) {
		return
	}
	mut profiles := map[string]ModelProfile{}
	for provider, profile in state.settings.profiles {
		profiles[provider] = profile_with_secret(profile, '', provider in providers)
	}
	payload := PersistedModelSettings{
		active_provider: state.settings.active_provider
		profiles:        profiles
		migration_note:  migration_restore_note
	}
	write_private_file_atomic(backup_path, json2.encode(payload)) or {}
}

// sync_file_mode is the rollback path: profiles still referencing the
// keychain are copied back into the owner-only file, then the keychain
// entries are removed. Nothing changes unless every key could be read.
fn (mut state ModelSettingsState) sync_file_mode() {
	mut providers := []string{}
	for provider, profile in state.settings.profiles {
		if profile.key_in_keychain && profile.api_key.len == 0 {
			providers << provider
		}
	}
	if providers.len == 0 {
		return
	}
	providers.sort()
	mut restored := state.settings.profiles.clone()
	for provider in providers {
		stored := state.backend.get(model_secret_account(state.scope, provider)) or {
			state.fail_secret_sync(err.msg())
			break
		}
		if stored.len == 0 {
			state.fail_secret_sync('the keychain entry for ${provider} is missing')
			break
		}
		restored[provider] = profile_with_secret(restored[provider], stored, false)
	}
	if state.secret_error != '' {
		for provider in providers {
			state.unavailable[provider] = true
		}
		return
	}
	updated := PersistedModelSettings{
		active_provider: state.settings.active_provider
		profiles:        restored
	}
	state.persist(updated) or {
		state.fail_secret_sync(err.msg())
		for provider in providers {
			state.unavailable[provider] = true
		}
		return
	}
	state.settings = updated
	for provider in providers {
		state.backend.delete(model_secret_account(state.scope, provider)) or {}
	}
}

// api_key_for returns the saved key for a provider, or an actionable error
// when it exists but the keychain cannot deliver it right now.
fn (mut state ModelSettingsState) api_key_for(provider string) !string {
	state.mu.lock()
	defer { state.mu.unlock() }
	state.retry_secret_sync()
	if state.unavailable[provider] {
		return error(state.secret_error)
	}
	profile := state.settings.profiles[provider] or { return '' }
	return profile.api_key
}
