module main

import os
import uuid

// A user whose only agent is an installed CLI (Claude Code, Codex, ...) has no
// HTTP provider credentials. A per-turn CLI override must not require the
// global default provider to be usable.

fn turn_config_test_app(root string) (&Store, &App) {
	mut store := open_store(os.join_path(root, 'veasel.sqlite3')) or { panic(err) }
	plugin_dir := os.join_path(root, 'plugins')
	os.mkdir_all(plugin_dir) or { panic(err) }
	return store, new_app(store, plugin_dir)
}

fn with_clean_model_env(f fn ()) {
	names := ['VEASEL_MODEL', 'VEASEL_MODEL_PROVIDER', 'VEASEL_MODEL_API_KEY', 'VEASEL_MODEL_BASE_URL']
	mut previous := map[string]string{}
	for name in names {
		previous[name] = os.getenv(name)
		os.unsetenv(name)
	}
	f()
	for name in names {
		if previous[name].len > 0 {
			os.setenv(name, previous[name], true)
		}
	}
}

fn test_cli_override_does_not_require_global_default_credentials() {
	with_clean_model_env(fn () {
		root := os.join_path(os.temp_dir(), 'veasel-turn-config-${uuid.new_v4().str()}')
		os.mkdir_all(root) or { panic(err) }
		mut store, app := turn_config_test_app(root)
		defer {
			app.close()
			store.close() or {}
			os.rmdir_all(root) or {}
		}
		// Precondition: the global default really is unusable here.
		if _ := app.model_config_for_session('session-id') {
			assert false, 'test precondition: no global default should be configured'
		}
		cli := ModelConfig{
			provider: 'claude-code'
			model:    'default'
		}
		config := app.turn_model_config('session-id', cli) or {
			assert false, 'a CLI override must resolve without global credentials: ${err.msg()}'
			return
		}
		assert config.provider == 'claude-code'
		assert config.model == 'default'
		assert config.session_id == 'session-id'
		// Without an override the unusable default is still reported honestly.
		if _ := app.turn_model_config('session-id', none) {
			assert false, 'no override and no default must fail'
		}
	})
}
