module main

fn test_headless_config_parses_model_get_and_set() {
	got := parse_headless_config_args(['model', 'get', '--json']) or { panic(err) }
	assert got.action == .model_get
	assert got.json

	set := parse_headless_config_args([
		'model',
		'set',
		'--provider',
		'meta',
		'--model',
		'muse-wonder-1.0',
		'--base-url',
		'https://api.meta.ai/v1',
		'--max-output-tokens',
		'8192',
	]) or { panic(err) }
	assert set.action == .model_set
	assert set.provider == 'meta'
	assert set.model == 'muse-wonder-1.0'
	assert set.base_url == 'https://api.meta.ai/v1'
	assert set.has_max_output
	assert (set.max_output_tokens or { -1 }) == 8192

	zero := parse_headless_config_args([
		'model',
		'set',
		'--provider',
		'meta',
		'--max-output-tokens',
		'0',
	]) or { panic(err) }
	assert (zero.max_output_tokens or { -1 }) == 0

	if _ := parse_headless_config_args(['model', 'set', '--max-output-tokens', '8']) {
		assert false
	}
	if _ := parse_headless_config_args(['model', 'set']) {
		assert false
	}
	if _ := parse_headless_config_args([
		'model',
		'set',
		'--provider',
		'meta',
		'--api-key',
		'secret',
		'--clear-api-key',
	]) {
		assert false
	}
}

fn test_format_headless_model_settings_view_never_includes_secrets() {
	text := format_headless_model_settings_view(ModelSettingsView{
		active_provider: 'meta'
		profiles:        {
			'meta': ModelProfileView{
				model:             'muse-wonder-1.0'
				base_url:          'https://api.meta.ai/v1'
				api_key_saved:     true
				max_output_tokens: 0
			}
		}
	})
	assert text.contains('Active provider: meta')
	assert text.contains('budget=0')
	assert text.contains('key=saved')
	assert !text.contains('sk-')
	assert !text.contains('api_key=')
}
