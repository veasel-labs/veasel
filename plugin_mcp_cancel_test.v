module main

fn test_plugin_mcp_cancelled_notification_encoding() {
	numeric := plugin_mcp_cancelled_notification('7', 'turn cancelled')
	assert numeric.contains('"method":"notifications/cancelled"')
	assert numeric.contains('"requestId":7')
	assert numeric.contains('"reason":"turn cancelled"')

	quoted := plugin_mcp_cancelled_notification('"req-1"', 'user stop')
	assert quoted.contains('"requestId":"req-1"')
}

fn test_plugin_mcp_jsonrpc_request_id_extraction() {
	assert plugin_mcp_jsonrpc_request_id_json('{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{}}') == '3'
	assert plugin_mcp_jsonrpc_request_id_json('{"jsonrpc":"2.0","id":"abc","method":"tools/call","params":{}}') == '"abc"'
	assert plugin_mcp_jsonrpc_request_id_json('{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}') == ''
	assert plugin_mcp_jsonrpc_request_id_json('{"jsonrpc":"2.0","method":"notifications/initialized"}') == ''
}
