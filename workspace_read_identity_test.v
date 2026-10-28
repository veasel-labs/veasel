module main

fn test_workspace_read_identity_does_not_confuse_literal_names_with_ranges() {
	whole := ProviderToolCall{
		function: ProviderFunctionCall{
			name:      'workspace_read_file'
			arguments: '{"path":"source#1:2"}'
		}
	}
	ranged := ProviderToolCall{
		function: ProviderFunctionCall{
			name:      'workspace_read_file'
			arguments: '{"path":"source","start_line":1,"line_count":2}'
		}
	}
	assert workspace_read_identity_from_call(whole) or { panic('missing identity') } != workspace_read_identity_from_call(ranged) or { panic('missing identity') }
}

fn test_invalid_ranges_never_enter_the_successful_read_cache() {
	for arguments in [
		'{"path":"source","start_line":1}',
		'{"path":"source","start_line":1.5,"line_count":2}',
		'{"path":"source","start_line":0,"line_count":2}',
		'{"path":"source","start_line":1,"line_count":201}',
		'{"path":"source","start_line":"1","line_count":2}',
		'{"path":"source","start_line":1,"line_count":null}',
		'{"path":"source","start_line":1,"line_count":2,"extra":true}',
	] {
		call := ProviderToolCall{
			function: ProviderFunctionCall{
				name:      'workspace_read_file'
				arguments: arguments
			}
		}
		assert workspace_read_identity_from_call(call) == none
		result := execute_workspace_read_file_tool('.', call)
		assert !result.workspace_read_succeeded
		assert result.result.contains('error')
	}
}
