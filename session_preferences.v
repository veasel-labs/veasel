module main

import json2
import veb

// Server-persisted per-session provider/model/permission choices (epic #689).
//
// Resolution order for every turn, stamped on the operation:
//   1. explicit per-turn override (provider/model/permission_mode on the POST)
//   2. the session preference stored here
//   3. the global default (model settings / backend default)
// A stored provider that is no longer available is a typed error, never a
// silent fallback: Veasel must not run a different provider than displayed.

const session_prefs_max_body_bytes = 4_096

struct SessionPreferencesConflict {
pub:
	error   string
	code    string
	session Session
}

struct SessionPreferencesError {
pub:
	error string
	code  string
}

// ResolvedTurnPreferences is the admitted form of a turn: the input with the
// session preference folded in, plus where each value came from.
struct ResolvedTurnPreferences {
	input             ChatMessageInput
	target_source     string // 'turn', 'session' or 'default'
	permission_source string // 'turn' or 'session'
	provider          string // resolved provider id, informational for 'default'
	model             string
}

// resolve_explicit_target validates and resolves a provider/model pair with
// the same rules as a per-turn target: provider and model together, or an
// installed-CLI provider alone. A model alone is rejected.
fn (app &App) resolve_explicit_target(provider string, model string) !ModelConfig {
	if provider.len > 0 && model.len == 0 && provider_cli_by_id(provider) != none {
		// Installed-CLI providers own their model choice: a provider-only
		// target runs THAT provider with its configured/default model rather
		// than silently inheriting the global provider.
		return app.provider_model_config(provider, '')
	}
	if provider.len == 0 || model.len == 0 {
		return error('provider and model must be supplied together')
	}
	return app.provider_model_config_for_target(provider, model)
}

// check_permission_mode_for_provider fails closed when the resolved provider
// cannot honor the mode, instead of letting the turn run with another one.
fn check_permission_mode_for_provider(provider string, permission_mode string) ! {
	if provider.len == 0 || permission_mode.len == 0 {
		return
	}
	spec := provider_cli_by_id(provider) or { return }
	if permission_mode !in spec.permission_modes {
		return error('${spec.name} does not support permission mode "${permission_mode}"')
	}
}

// session_has_active_turn reports whether an in-flight turn is registered for
// the session. Synchronous turns exist only in this registry until they
// complete, so the durable queue alone cannot answer this.
fn (app &App) session_has_active_turn(session_id string) bool {
	mut registry := app.operation_registry
	mut registry_lock := registry.mutex
	registry_lock.lock()
	defer {
		registry_lock.unlock()
	}
	for _, operation in registry.operations {
		if operation.session_id == session_id {
			return true
		}
	}
	return false
}

// resolve_turn_preferences folds the session preference into a turn input.
// The returned input carries explicit provider/model/permission_mode values
// so the queued request is immutable: a later preference change cannot alter
// a turn that was already admitted.
fn (app &App) resolve_turn_preferences(session Session, input ChatMessageInput) !ResolvedTurnPreferences {
	turn_target := input.provider.len > 0 || input.model.len > 0
	mut provider := input.provider
	mut model := input.model
	mut target_source := 'turn'
	if !turn_target {
		if session.preferred_provider.len > 0 {
			provider = session.preferred_provider
			model = session.preferred_model
			target_source = 'session'
			app.resolve_explicit_target(provider, model) or {
				return error('session_provider_unavailable')
			}
		} else {
			target_source = 'default'
		}
	}
	turn_permission := input.permission_mode.trim_space()
	permission_mode := if turn_permission.len > 0 {
		turn_permission
	} else {
		session.permission_mode
	}
	permission_source := if turn_permission.len > 0 { 'turn' } else { 'session' }
	if permission_mode !in valid_session_permission_modes {
		return error('permission_mode is invalid')
	}
	// Judge the mode against the provider that will actually run.
	mut effective_provider := provider
	if target_source == 'default' {
		config := app.model_config_for_session(session.id) or { ModelConfig{} }
		effective_provider = config.provider
		model = config.model
	}
	check_permission_mode_for_provider(effective_provider, permission_mode) or {
		return error('session_permission_unsupported:${err.msg()}')
	}
	return ResolvedTurnPreferences{
		input:             ChatMessageInput{
			content:          input.content
			provider:         if target_source == 'default' { '' } else { provider }
			model:            if target_source == 'default' { '' } else { model }
			permission_mode:  permission_mode
			collect_trace:    input.collect_trace
			autonomous:       input.autonomous
			execution_policy: input.execution_policy
			non_interactive:  input.non_interactive
		}
		target_source:     target_source
		permission_source: permission_source
		provider:          effective_provider
		model:             model
	}
}

fn session_preference_error_response(mut ctx Context, err IError) veb.Result {
	message := err.msg()
	if message == 'session_provider_unavailable' {
		ctx.res.set_status(.conflict)
		return ctx.json(SessionPreferencesError{
			error: 'The provider chosen for this session is no longer available. Pick another provider for the session; Veasel will not run a different one silently.'
			code:  'session_provider_unavailable'
		})
	}
	if message.starts_with('session_permission_unsupported:') {
		ctx.res.set_status(.conflict)
		return ctx.json(SessionPreferencesError{
			error: message.all_after('session_permission_unsupported:')
			code:  'session_permission_unsupported'
		})
	}
	return json_request_error(mut ctx, message)
}

// validate_session_create_preferences checks the optional preferences on a
// session-create request. It returns the normalized input.
fn (app &App) validate_session_create_preferences(input SessionInput) !SessionInput {
	provider := input.preferred_provider.trim_space()
	model := input.preferred_model.trim_space()
	mode := if input.permission_mode.trim_space().len == 0 {
		'ask'
	} else {
		input.permission_mode.trim_space()
	}
	if mode !in valid_session_permission_modes {
		return error('permission_mode is invalid')
	}
	if mode == 'bypass' && !input.confirm_bypass {
		return error('permission_mode "bypass" requires confirm_bypass: true')
	}
	if provider.len > 0 || model.len > 0 {
		app.resolve_explicit_target(provider, model)!
		check_permission_mode_for_provider(provider, mode)!
	}
	return SessionInput{
		title:              input.title
		directory:          input.directory
		preferred_provider: provider
		preferred_model:    model
		permission_mode:    mode
		confirm_bypass:     input.confirm_bypass
	}
}

fn raw_pref_string(raw map[string]json2.Any, key string) !string {
	value := raw[key] or { return '' }
	if value is string {
		return (value as string).trim_space()
	}
	return error('${key} must be a string')
}

// patch_session renames a session and/or changes its preferences. Preference
// changes require expected_prefs_version (optimistic concurrency) and are
// refused with 409 while a turn is queued, running or cancelling.
fn (app &App) patch_session(mut ctx Context, id string) veb.Result {
	if ctx.req.data.len > session_prefs_max_body_bytes {
		return json_request_error(mut ctx, 'Session update exceeds the size limit')
	}
	raw := json2.decode[map[string]json2.Any](ctx.req.data) or {
		return json_request_error(mut ctx, 'Expected JSON with title or session preferences')
	}
	has_title := 'title' in raw
	has_target := 'preferred_provider' in raw || 'preferred_model' in raw
	has_permission := 'permission_mode' in raw
	if !has_title && !has_target && !has_permission {
		return json_request_error(mut ctx, 'Expected JSON with title or session preferences')
	}
	mut store := app.store
	mut title := ''
	if has_title {
		title = raw_pref_string(raw, 'title') or { return json_request_error(mut ctx, err.msg()) }
		if !valid_session_title(title) {
			return json_request_error(mut ctx, 'Title must contain 1 to 200 printable characters without control bytes')
		}
	}
	mut session := store.get_session(id) or {
		ctx.res.set_status(.not_found)
		return ctx.json(APIError{
			error: 'session not found'
		})
	}
	if has_target || has_permission {
		version_value := raw['expected_prefs_version'] or {
			return json_request_error(mut ctx, 'expected_prefs_version is required to change session preferences')
		}
		expected_version := prefs_version_from_any(version_value)
		if expected_version < 0 {
			return json_request_error(mut ctx, 'expected_prefs_version must be a non-negative integer')
		}
		mut patch := SessionPreferencesPatch{}
		if has_target {
			// A target change always replaces both halves: an absent half is
			// empty, so a model-only change is rejected rather than merged
			// with a stale provider.
			provider := raw_pref_string(raw, 'preferred_provider') or {
				return json_request_error(mut ctx, err.msg())
			}
			model := raw_pref_string(raw, 'preferred_model') or {
				return json_request_error(mut ctx, err.msg())
			}
			if provider.len > 0 || model.len > 0 {
				app.resolve_explicit_target(provider, model) or {
					return json_request_error(mut ctx, err.msg())
				}
			}
			patch = SessionPreferencesPatch{
				...patch
				set_target:         true
				preferred_provider: provider
				preferred_model:    model
			}
		}
		if has_permission {
			mode := raw_pref_string(raw, 'permission_mode') or {
				return json_request_error(mut ctx, err.msg())
			}
			if mode !in valid_session_permission_modes {
				return json_request_error(mut ctx, 'permission_mode is invalid')
			}
			confirm_value := raw['confirm_bypass'] or { json2.Any(false) }
			confirm := if confirm_value is bool { confirm_value as bool } else { false }
			if mode == 'bypass' && !confirm {
				return json_request_error(mut ctx, 'permission_mode "bypass" requires confirm_bypass: true')
			}
			patch = SessionPreferencesPatch{
				...patch
				set_permission:  true
				permission_mode: mode
				confirm_bypass:  confirm
			}
		}
		effective_provider := if patch.set_target {
			patch.preferred_provider
		} else {
			session.preferred_provider
		}
		effective_mode := if patch.set_permission {
			patch.permission_mode
		} else {
			session.permission_mode
		}
		check_permission_mode_for_provider(effective_provider, effective_mode) or {
			return json_request_error(mut ctx, err.msg())
		}
		if app.session_has_active_turn(id) {
			return session_preferences_conflict(mut ctx, store, id, 'session_busy')
		}
		session = store.update_session_preferences(id, expected_version, patch) or {
			if err.msg() in ['prefs_version_conflict', 'session_busy'] {
				return session_preferences_conflict(mut ctx, store, id, err.msg())
			}
			if err.msg() == 'session not found' {
				ctx.res.set_status(.not_found)
				return ctx.json(APIError{
					error: 'session not found'
				})
			}
			eprintln('veasel: update session preferences failed: ${err}')
			return json_server_error(mut ctx, 'Unable to update session preferences')
		}
	}
	if has_title {
		session = store.rename_session(id, title) or {
			if err.msg() == 'session not found' {
				ctx.res.set_status(.not_found)
				return ctx.json(APIError{
					error: 'session not found'
				})
			}
			eprintln('veasel: rename session failed: ${err}')
			return json_server_error(mut ctx, 'Unable to rename session')
		}
	}
	return ctx.json(session)
}

fn session_preferences_conflict(mut ctx Context, store &Store, id string, code string) veb.Result {
	mut mutable_store := store
	current := mutable_store.get_session(id) or {
		ctx.res.set_status(.not_found)
		return ctx.json(APIError{
			error: 'session not found'
		})
	}
	ctx.res.set_status(.conflict)
	return ctx.json(SessionPreferencesConflict{
		error:   if code == 'session_busy' {
			'Session preferences cannot change while a turn is queued or running.'
		} else {
			'Session preferences changed since prefs_version ${current.prefs_version}; reload and retry.'
		}
		code:    code
		session: current
	})
}

// prefs_version_from_any accepts only whole JSON numbers; anything else
// (strings, booleans, fractions, null) is -1 so the caller rejects it.
fn prefs_version_from_any(value json2.Any) int {
	if value is string || value is bool || value is []json2.Any || value is map[string]json2.Any {
		return -1
	}
	if value is f64 {
		number := value as f64
		return if number == f64(int(number)) { int(number) } else { -1 }
	}
	if value is f32 {
		number := value as f32
		return if number == f32(int(number)) { int(number) } else { -1 }
	}
	return value.int()
}
