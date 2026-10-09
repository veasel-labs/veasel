module main

import json2
import net.urllib
import os
import strconv
import strings

fn load_plugin_mcp(root string, manifest map[string]json2.Any, mut plugin AgentPlugin) {
	_ := os.lstat(os.join_path(root, 'mcp.json')) or { return }
	mcp_path := plugin_path(root, 'mcp.json') or {
		plugin.diagnostics << PluginDiagnostic{
			component: 'mcp.json'
			message:   'Ignoring MCP configuration outside the plugin root'
		}
		return
	}
	if !os.is_file(mcp_path) {
		plugin.diagnostics << PluginDiagnostic{
			component: 'mcp.json'
			message:   'Ignoring invalid MCP component: expected a regular file'
		}
		return
	}
	text := read_plugin_file(mcp_path, max_plugin_manifest_bytes) or {
		plugin.diagnostics << PluginDiagnostic{
			component: 'mcp.json'
			message:   'Unable to read MCP configuration'
		}
		return
	}
	fields := json2.decode[map[string]json2.Any](text) or {
		plugin.diagnostics << PluginDiagnostic{
			component: 'mcp.json'
			message:   'Ignoring invalid MCP JSON'
		}
		return
	}
	servers := validate_plugin_mcp(root, fields, manifest, mut plugin.diagnostics) or {
		plugin.diagnostics << PluginDiagnostic{
			component: 'mcp.json'
			message:   'Ignoring invalid MCP component: ${err.msg()}'
		}
		return
	}
	plugin.mcp_servers = servers
}

fn validate_plugin_mcp(root string, fields map[string]json2.Any, manifest map[string]json2.Any, mut diagnostics []PluginDiagnostic) ![]PluginMCPServer {
	for key, _ in fields {
		if key !in [plugin_schema_key, 'mcpServers'] {
			return error('unknown mcp.json top-level field `${key}`')
		}
	}
	schema := plugin_required_string(fields, plugin_schema_key)!
	manifest_schema := plugin_required_string(manifest, plugin_schema_key)!
	if schema != plugin_mcp_schema || manifest_schema != plugin_manifest_schema {
		return error('unsupported Agent Plugins MCP schema')
	}
	server_values := fields['mcpServers'] or { return error('mcpServers is required') }
	if server_values !is map[string]json2.Any {
		return error('mcpServers must be an object')
	}
	if (server_values as map[string]json2.Any).len > max_plugin_mcp_servers {
		return error('mcpServers exceeds the ${max_plugin_mcp_servers} server limit')
	}
	mut servers := []PluginMCPServer{}
	for name, value in server_values as map[string]json2.Any {
		server := parse_plugin_mcp_server(root, name, value) or {
			diagnostics << PluginDiagnostic{
				component: 'mcpServers.${name}'
				message:   'Skipping invalid MCP server: ${err.msg()}'
			}
			continue
		}
		servers << server
	}
	return servers
}

fn parse_plugin_mcp_server(root string, name string, value json2.Any) !PluginMCPServer {
	if value !is map[string]json2.Any {
		return error('server entry must be an object')
	}
	fields := value as map[string]json2.Any
	transport_type := plugin_required_string(fields, 'type')!
	match transport_type {
		'stdio' {
			for key, _ in fields {
				if key !in ['type', 'command', 'args', 'env', 'cwd'] {
					return error('unknown stdio field `${key}`')
				}
			}
			command := plugin_required_string(fields, 'command')!
			if command.contains('\0') || command.contains('\n') || command.contains('\r')
				|| command.trim_space() != command {
				return error('command must be one executable token')
			}
			resolved_command := if command.starts_with('./') {
				contained := plugin_path(root, command[2..])!
				if !os.is_file(contained) {
					return error('plugin-relative command is not a file')
				}
				contained
			} else {
				if command.contains('/') || command.contains('\\') {
					return error('bare command must not contain a path separator')
				}
				command
			}
			mut args := []string{}
			if raw_args := fields['args'] {
				if raw_args !is []json2.Any {
					return error('args must be an array of strings')
				}
				if (raw_args as []json2.Any).len > max_plugin_mcp_args {
					return error('args exceeds the ${max_plugin_mcp_args} entry limit')
				}
				for arg in raw_args as []json2.Any {
					if arg !is string {
						return error('args must be an array of strings')
					}
					argument := arg as string
					if argument.contains('\0') {
						return error('arguments must not contain NUL bytes')
					}
					args << argument
				}
			}
			mut env := map[string]string{}
			if raw_env := fields['env'] {
				if raw_env !is map[string]json2.Any {
					return error('env must be an object of strings')
				}
				if (raw_env as map[string]json2.Any).len > max_plugin_mcp_env {
					return error('env exceeds the ${max_plugin_mcp_env} entry limit')
				}
				for key, raw_value in raw_env as map[string]json2.Any {
					if key.len == 0 || key.contains('=') || key.contains('\0')
						|| key.to_upper() in ['PLUGIN_ROOT', 'PLUGIN_DATA'] || raw_value !is string {
						return error('env entries are invalid or use reserved names')
					}
					env_value := raw_value as string
					if env_value.contains('\0') {
						return error('environment values must not contain NUL bytes')
					}
					env[key] = env_value
				}
			}
			mut cwd := ''
			if raw_cwd := fields['cwd'] {
				if raw_cwd !is string {
					return error('cwd must be a string')
				}
				cwd = raw_cwd as string
				validate_plugin_cwd(root, cwd)!
			}
			return PluginMCPServer{
				name:      name
				transport: transport_type
				command:   resolved_command
				args:      args
				cwd:       cwd
				env:       env
			}
		}
		'streamable-http' {
			for key, _ in fields {
				if key !in ['type', 'url', 'headers'] {
					return error('unknown HTTP MCP field `${key}`')
				}
			}
			url := validate_plugin_mcp_url(plugin_required_string(fields, 'url')!)!
			mut headers := map[string]string{}
			if raw_headers := fields['headers'] {
				if raw_headers !is map[string]json2.Any {
					return error('headers must be an object of strings')
				}
				if (raw_headers as map[string]json2.Any).len > max_plugin_mcp_headers {
					return error('headers exceeds the ${max_plugin_mcp_headers} entry limit')
				}
				for key, raw_value in raw_headers as map[string]json2.Any {
					if raw_value !is string || !valid_http_header(key, raw_value as string) {
						return error('HTTP header is invalid')
					}
					for existing, _ in headers {
						if existing.to_lower() == key.to_lower() {
							return error('HTTP header names must be unique regardless of case')
						}
					}
					headers[key] = raw_value as string
				}
			}
			return PluginMCPServer{
				name:      name
				transport: transport_type
				url:       url
				headers:   headers
			}
		}
		else {
			return error('unsupported MCP transport')
		}
	}
}

fn validate_plugin_cwd(root string, cwd string) ! {
	if cwd.contains('\0') {
		return error('cwd must not contain NUL bytes')
	}
	root_token := '$' + '{PLUGIN_ROOT}'
	data_token := '$' + '{PLUGIN_DATA}'
	if cwd == './' {
		return
	}
	if cwd.starts_with('./') {
		resolved := plugin_path(root, cwd[2..])!
		if !os.is_dir(resolved) {
			return error('plugin-relative cwd must resolve to a directory')
		}
		return
	}
	for placeholder in [root_token, data_token] {
		if cwd == placeholder {
			return
		}
		if cwd.starts_with(placeholder + '/') {
			suffix := cwd[placeholder.len + 1..]
			if os.is_abs_path(suffix) || '..' in suffix.split('/')
				|| suffix.contains('\\') {
				return error('placeholder cwd must remain within its configured root')
			}
			if placeholder == root_token && suffix.len > 0 {
				resolved := plugin_path(root, suffix)!
				if !os.is_dir(resolved) {
					return error('plugin-root cwd must resolve to a directory')
				}
			}
			return
		}
	}
	return error('cwd must use plugin-relative or supported plugin-root placeholders')
}

// resolve_plugin_cwd applies cwd placeholders only after the installer has
// created the persistent data directory. Existing symlinks are resolved and
// checked against the selected root before a process is launched.
fn resolve_plugin_cwd(plugin_root string, plugin_data string, configured string) !string {
	root := canonical_plugin_root(plugin_root)!
	data := canonical_plugin_root(plugin_data)!
	cwd := if configured == '' { './' } else { configured }
	validate_plugin_cwd(root, cwd)!
	root_token := '$' + '{PLUGIN_ROOT}'
	data_token := '$' + '{PLUGIN_DATA}'
	if cwd == './' || cwd == root_token {
		return root
	}
	if cwd == data_token {
		return data
	}
	if cwd.starts_with('./') {
		return plugin_directory_path(root, cwd[2..])!
	}
	if cwd.starts_with(root_token + '/') {
		return plugin_directory_path(root, cwd[root_token.len + 1..])!
	}
	if cwd.starts_with(data_token + '/') {
		return plugin_directory_path(data, cwd[data_token.len + 1..])!
	}
	return error('cwd must resolve beneath the plugin root or data directory')
}

fn plugin_directory_path(root string, relative string) !string {
	if relative.len == 0 {
		return canonical_plugin_root(root)
	}
	resolved := plugin_path(root, relative)!
	if !os.is_dir(resolved) {
		return error('cwd must resolve to a directory')
	}
	return resolved
}

fn validate_plugin_mcp_url(value string) !string {
	if value.contains('\0') || value.contains('\r') || value.contains('\n')
		|| value.contains('$' + '{') {
		return error('MCP URL is invalid')
	}
	parsed := urllib.parse(value) or { return error('MCP URL is invalid') }
	scheme := parsed.scheme.to_lower()
	hostname := parsed.hostname()
	if parsed.host == '' || hostname.trim_space().len == 0 || value.contains('#')
		|| scheme !in ['http', 'https'] {
		return error('MCP URL must be absolute HTTP(S) without user information or fragment')
	}
	if userinfo := parsed.user {
		if userinfo.username != '' || userinfo.password != '' || userinfo.password_set {
			return error('MCP URL must not contain user information')
		}
	}
	colon := value.index(':') or { return error('MCP URL is invalid') }
	if value.len <= colon + 3 || value[colon + 1..].len < 2
		|| !value[colon + 1..].starts_with('//') {
		return error('MCP URL must include an authority')
	}
	authority_start := colon + 3
	mut authority_end := value.len
	for delimiter in [`/`, `?`, `#`] {
		delimiter_index := value[authority_start..].index_u8(delimiter)
		if delimiter_index >= 0 {
			candidate := authority_start + delimiter_index
			if candidate < authority_end {
				authority_end = candidate
			}
		}
	}
	validate_plugin_mcp_authority(value[authority_start..authority_end])!
	authority := value[authority_start..authority_end]
	if !authority.starts_with('[') && !valid_plugin_hostname(hostname) {
		return error('MCP URL hostname is invalid')
	}
	if scheme != 'https' && !is_loopback_plugin_host(parsed.host) {
		return error('remote MCP endpoints must use HTTPS')
	}
	return scheme + value[colon..]
}

fn valid_plugin_hostname(hostname string) bool {
	if hostname.trim_space().len == 0 || hostname != hostname.trim_space()
		|| hostname.contains('\\') {
		return false
	}
	for c in hostname {
		if c <= 32 || c >= 127 || c in [`/`, `?`, `#`, `@`, `:`, `[`, `]`] {
			return false
		}
	}
	return true
}

fn validate_plugin_mcp_authority(authority string) ! {
	if authority.len == 0 || authority.contains('@') {
		return error('MCP URL authority is invalid')
	}
	if authority.starts_with('[') {
		closing := authority.index(']') or { return error('MCP URL IPv6 literal is invalid') }
		if closing == 1 {
			return error('MCP URL IPv6 literal is empty')
		}
		suffix := authority[closing + 1..]
		if suffix.len == 0 {
			return
		}
		if !suffix.starts_with(':') || !valid_port(suffix[1..]) {
			return error('MCP URL port must be between 1 and 65535')
		}
		return
	}
	if authority.count(':') > 1 {
		return error('IPv6 MCP URLs must use brackets')
	}
	colon := authority.index(':') or {
		if authority.trim_space().len == 0 {
			return error('MCP URL hostname is empty')
		}
		return
	}
	if colon == 0 || !valid_port(authority[colon + 1..]) {
		return error('MCP URL port must be between 1 and 65535')
	}
}

fn is_loopback_plugin_host(value string) bool {
	mut host := value.to_lower()
	if host == 'localhost' || host.starts_with('localhost:') {
		if host == 'localhost' {
			return true
		}
		return valid_port(host['localhost:'.len..])
	}
	if host.starts_with('[') {
		closing := host.index(']') or { return false }
		if host[1..closing] != '::1' || !valid_optional_port(host[closing + 1..]) {
			return false
		}
		return true
	}
	if host.count(':') == 1 {
		parts := host.split(':')
		if !valid_port(parts[1]) {
			return false
		}
		host = parts[0]
	} else if host.contains(':') {
		return false
	}
	octets := host.split('.')
	if octets.len != 4 || octets[0] != '127' {
		return false
	}
	for octet in octets {
		numeric_octet := strconv.atoi(octet) or { return false }
		if numeric_octet < 0 || numeric_octet > 255 {
			return false
		}
	}
	return true
}

fn expand_plugin_placeholders(value string, plugin_root string, plugin_data string) string {
	root_token := '$' + '{PLUGIN_ROOT}'
	data_token := '$' + '{PLUGIN_DATA}'
	mut output := strings.new_builder(value.len)
	mut index := 0
	for index < value.len {
		remaining := value[index..]
		if remaining.starts_with(root_token) {
			output.write_string(plugin_root)
			index += root_token.len
		} else if remaining.starts_with(data_token) {
			output.write_string(plugin_data)
			index += data_token.len
		} else {
			output.write_u8(value[index])
			index++
		}
	}
	return output.str()
}

fn valid_http_header(name string, value string) bool {
	if name.len == 0 || value.contains('\r') || value.contains('\n') {
		return false
	}
	for c in name {
		if c <= 32 || c >= 127 || c in [`(`, `)`, `<`, `>`, `@`, `,`, `;`, `:`, `\\`, `"`, `/`,
			`[`, `]`, `?`, `=`, `{`, `}`] {
			return false
		}
	}
	for c in value {
		if (c < 32 && c != `\t`) || c == 127 {
			return false
		}
	}
	return true
}
