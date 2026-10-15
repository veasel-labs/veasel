module main

import json2
import net.http
import os

// Headless model settings. Calls /v1/config/model. Never prints API keys.

enum HeadlessConfigAction {
	model_get
	model_set
}

struct HeadlessConfigOptions {
mut:
	action            HeadlessConfigAction
	provider          string
	model             string
	base_url          string
	api_key           string
	clear_api_key     bool
	max_output_tokens ?int
	has_max_output    bool
	json              bool
}

fn print_headless_config_help() {
	println('Usage: veasel config model <get|set> [options]\n\nCommands:\n  model get [--json]\n  model set --provider <id> [--model <name>] [--base-url <url>] [--api-key <secret>] [--clear-api-key] [--max-output-tokens <n>]\n\nOptions:\n      --json                 Emit machine-readable JSON\n      --max-output-tokens n  Per-provider output budget (0 = Veasel default / Meta omit; 16–131072)\n  -h, --help                 Show this help\n\nAPI keys are never printed. Empty --api-key preserves an existing key; --clear-api-key removes it.\nPersistence: \$VEASEL_DATA_DIR/model-settings.json (owner-only when the platform supports chmod).')
}

fn parse_headless_config_args(args []string) !HeadlessConfigOptions {
	mut options := HeadlessConfigOptions{}
	if args.len == 0 {
		return error('help')
	}
	mut index := 0
	group := args[index]
	index++
	if group in ['--help', '-h', 'help'] {
		return error('help')
	}
	if group != 'model' {
		return error('unknown config command: ${group}')
	}
	if index >= args.len {
		return error('config model expects get|set')
	}
	action := args[index]
	index++
	match action {
		'get' {
			options.action = .model_get
		}
		'set' {
			options.action = .model_set
		}
		'--help', '-h', 'help' {
			return error('help')
		}
		else {
			return error('unknown config model command: ${action}')
		}
	}
	for index < args.len {
		arg := args[index]
		match arg {
			'--json' {
				options.json = true
				index++
			}
			'--provider' {
				index++
				if index >= args.len || args[index].trim_space().len == 0 {
					return error('--provider expects a provider id')
				}
				options.provider = args[index].trim_space()
				index++
			}
			'--model' {
				index++
				if index >= args.len || args[index].trim_space().len == 0 {
					return error('--model expects a model id')
				}
				options.model = args[index].trim_space()
				index++
			}
			'--base-url' {
				index++
				if index >= args.len || args[index].trim_space().len == 0 {
					return error('--base-url expects a URL')
				}
				options.base_url = args[index].trim_space()
				index++
			}
			'--api-key' {
				index++
				if index >= args.len {
					return error('--api-key expects a value')
				}
				options.api_key = args[index]
				index++
			}
			'--clear-api-key' {
				options.clear_api_key = true
				index++
			}
			'--max-output-tokens' {
				index++
				if index >= args.len || args[index].trim_space().len == 0 {
					return error('--max-output-tokens expects an integer')
				}
				value := args[index].int()
				if !valid_max_output_tokens(value) {
					return error('--max-output-tokens must be 0 or between 16 and 131072')
				}
				options.max_output_tokens = value
				options.has_max_output = true
				index++
			}
			'--help', '-h' {
				return error('help')
			}
			else {
				return error('unknown config option: ${arg}')
			}
		}
	}
	if options.action == .model_set && options.provider.len == 0 {
		return error('config model set requires --provider')
	}
	if options.clear_api_key && options.api_key.len > 0 {
		return error('--clear-api-key cannot be combined with --api-key')
	}
	return options
}

fn headless_config_api_error(response http.Response) string {
	decoded := json2.decode[APIError](response.body) or { return 'HTTP ${response.status_code}' }
	if decoded.error.len > 0 {
		return decoded.error
	}
	return 'HTTP ${response.status_code}'
}

fn format_headless_model_settings_view(view ModelSettingsView) string {
	mut lines := []string{cap: view.profiles.len + 4}
	active := if view.active_provider.len > 0 { view.active_provider } else { '(none)' }
	lines << 'Active provider: ${active}'
	if view.profiles.len == 0 {
		lines << '(no saved profiles)'
	}
	for provider, profile in view.profiles {
		marker := if provider == view.active_provider { '*' } else { ' ' }
		key_state := if profile.api_key_saved { 'key=saved' } else { 'key=missing' }
		lines << '${marker} ${provider}  model=${profile.model}  budget=${profile.max_output_tokens}  ${key_state}  ${profile.base_url}'
	}
	return lines.join('\n')
}

fn execute_headless_config_model_get(port int, options HeadlessConfigOptions) !string {
	response := headless_json_request(port, .get, '/v1/config/model', '', false, '')!
	if response.status_code != 200 {
		return error(headless_config_api_error(response))
	}
	if options.json {
		return response.body
	}
	view := json2.decode[ModelSettingsView](response.body)!
	if response.body.contains('"api_key"') && response.body.contains('"api_key_saved"') == false {
		return error('refusing to print a response that may contain credentials')
	}
	return format_headless_model_settings_view(view)
}

fn execute_headless_config_model_set(port int, options HeadlessConfigOptions) !string {
	payload := ModelSettingsInput{
		provider:          options.provider
		model:             options.model
		base_url:          options.base_url
		api_key:           options.api_key
		clear_api_key:     options.clear_api_key
		max_output_tokens: if options.has_max_output {
			options.max_output_tokens
		} else {
			none
		}
	}
	response := headless_json_request(port, .post, '/v1/config/model', json2.encode(payload),
		false, '')!
	if response.status_code != 200 {
		return error(headless_config_api_error(response))
	}
	if options.json {
		return response.body
	}
	view := json2.decode[ModelSettingsView](response.body)!
	return format_headless_model_settings_view(view)
}

fn execute_headless_config_command(port int, args []string) {
	options := parse_headless_config_args(args) or {
		if err.msg() == 'help' {
			print_headless_config_help()
			return
		}
		eprintln('veasel: ${err.msg()}')
		print_headless_config_help()
		exit(2)
	}
	ensure_backend(port, '') or {
		eprintln('veasel: ${err.msg()}')
		exit(1)
	}
	output := match options.action {
		.model_get {
			execute_headless_config_model_get(port, options) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
		.model_set {
			execute_headless_config_model_set(port, options) or {
				eprintln('veasel: ${err.msg()}')
				exit(1)
			}
		}
	}
	println(output)
}
