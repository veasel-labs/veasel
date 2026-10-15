module main

import context as vcontext
import mcp
import json2
import os
import strconv
import strings
import time

const max_plugin_mcp_frame_bytes = 1_000_000
const plugin_mcp_response_timeout = 20 * time.second
const max_session_plugin_mcp_servers = 8
const max_plugin_mcp_concurrency = 4
const max_session_plugin_mcp_tools = 64
const max_session_plugin_mcp_tool_pages = 16
const max_session_plugin_mcp_cursor_bytes = 1024
const mcp_stdio_sandbox_mode_env = 'VEASEL_MCP_STDIO_SANDBOX'

struct PluginMCPToolBinding {
	connection_index int
	native_name      string
	plugin_name      string
	server_name      string
}

struct PluginMCPConnection {
mut:
	client          mcp.Client
	stdio_transport &PluginMCPTransport     = unsafe { nil }
	http_transport  &PluginMCPHTTPTransport = unsafe { nil }
}

// PluginMCPTransport supplies the process configuration missing from the
// stdlib convenience constructor while keeping MCP JSON-RPC in vlib/mcp.
// On Windows, win_mcp holds an AppContainer-backed stdio process when
// VEASEL_MCP_STDIO_SANDBOX wraps the child; otherwise process is used.
@[heap]
struct PluginMCPTransport {
mut:
	process            &os.Process = unsafe { nil }
	win_mcp            voidptr     = unsafe { nil } // &WindowsMcpStdioProcess on Windows
	buffer             string
	response_timeout   time.Duration = plugin_mcp_response_timeout
	cancel_requested   bool
	active_request_id  string
	cancelled_notified bool
}

fn mcp_stdio_sandbox_mode() ApprovedShellSandboxMode {
	// Default off: MCP stdio stays unsandboxed until operators opt into
	// auto/require. Empty VEASEL_SHELL_SANDBOX defaults to auto for shell;
	// do not inherit that default here.
	raw := os.getenv(mcp_stdio_sandbox_mode_env).trim_space().to_lower()
	if raw.len == 0 {
		return .off
	}
	return approved_shell_sandbox_mode_from(raw)
}

fn mcp_stdio_review_sandbox_preview() ReviewSandboxPreview {
	mode := mcp_stdio_sandbox_mode()
	mut backend := 'none'
	mut will_wrap := false
	if mcp_stdio_sandbox_bubblewrap_capability() {
		backend = 'bubblewrap'
		will_wrap = true
	} else if mcp_stdio_sandbox_seatbelt_capability() {
		backend = 'seatbelt'
		will_wrap = true
	} else if mcp_stdio_sandbox_windows_capability() {
		backend = 'windows'
		will_wrap = true
	}
	return ReviewSandboxPreview{
		mode:      approved_shell_sandbox_mode_label(mode)
		will_wrap: will_wrap
		backend:   backend
	}
}

fn warn_mcp_stdio_unsandboxed_default() {
	eprintln('veasel: trusted MCP stdio starts unsandboxed (VEASEL_MCP_STDIO_SANDBOX unset/off). Set VEASEL_MCP_STDIO_SANDBOX=auto or require for Linux Bubblewrap, macOS Seatbelt, or Windows AppContainer when available. Default stays off.')
}

// mcp_stdio_sandbox_bubblewrap_capability is true only when Linux Bubblewrap
// will actually wrap trusted stdio MCP processes for the current configuration.
fn mcp_stdio_sandbox_bubblewrap_capability() bool {
	$if linux {
		if mcp_stdio_sandbox_mode() == .off {
			return false
		}
		return bubblewrap_available()
	} $else {
		return false
	}
}

// mcp_stdio_sandbox_seatbelt_capability is true only when macOS Seatbelt will
// actually wrap trusted stdio MCP processes for the current configuration.
fn mcp_stdio_sandbox_seatbelt_capability() bool {
	$if macos {
		if mcp_stdio_sandbox_mode() == .off {
			return false
		}
		return seatbelt_available()
	} $else {
		return false
	}
}

// mcp_stdio_sandbox_windows_capability is true only when Windows AppContainer
// will actually wrap trusted stdio MCP processes for the current configuration.
fn mcp_stdio_sandbox_windows_capability() bool {
	$if windows {
		if mcp_stdio_sandbox_mode() == .off {
			return false
		}
		return windows_appcontainer_sandbox_available()
	} $else {
		return false
	}
}

fn start_plugin_mcp_transport(plugin_root string, plugin_data string, server PluginMCPServer) !&PluginMCPTransport {
	if server.transport != 'stdio' || server.command.len == 0 {
		return error('unsupported Agent Plugin MCP server')
	}
	root := canonical_plugin_root(plugin_root)!
	data_parent := os.dir(os.real_path(plugin_data))
	os.mkdir_all(data_parent)!
	os.mkdir_all(plugin_data)!
	data := canonical_plugin_root(plugin_data)!
	$if !windows {
		os.chmod(data, 0o700)!
	}
	cwd := resolve_plugin_cwd(root, data, server.cwd)!
	mut configured := map[string]string{}
	for key, value in server.env {
		configured[key] = expand_plugin_placeholders(value, root, data)
	}
	mut case_insensitive := false
	$if windows {
		case_insensitive = true
	}
	mut env := overlay_plugin_environment(plugin_mcp_base_environment(), configured, case_insensitive)
	env['PLUGIN_ROOT'] = root
	env['PLUGIN_DATA'] = data
	args := server.args.map(expand_plugin_placeholders(it, root, data))
	mode := mcp_stdio_sandbox_mode()
	$if linux {
		if mode != .off {
			if bubblewrap_available() {
				return start_plugin_mcp_transport_linux_sandboxed(root, data, cwd, server.command,
					args, env)
			}
			if mode == .require {
				return error('Trusted MCP stdio requires bubblewrap (bwrap) because VEASEL_MCP_STDIO_SANDBOX=require; no unsandboxed fallback was started')
			}
		}
	} $else $if macos {
		if mode != .off {
			if seatbelt_available() {
				return start_plugin_mcp_transport_macos_sandboxed(root, data, cwd, server.command,
					args, env)
			}
			if mode == .require {
				return error('Trusted MCP stdio requires /usr/bin/sandbox-exec because VEASEL_MCP_STDIO_SANDBOX=require; no unsandboxed fallback was started')
			}
		}
	} $else $if windows {
		if mode != .off {
			if windows_appcontainer_sandbox_available() {
				return start_plugin_mcp_transport_windows_sandboxed(root, data, cwd, server.command,
					args, env)
			}
			if mode == .require {
				return error('Trusted MCP stdio requires a Windows AppContainer because VEASEL_MCP_STDIO_SANDBOX=require; no unsandboxed fallback was started')
			}
		}
	} $else {
		if mode == .require {
			return error('VEASEL_MCP_STDIO_SANDBOX=require is only implemented for Linux Bubblewrap, macOS Seatbelt, and Windows AppContainer; refuse to start unsandboxed MCP stdio')
		}
	}
	if mode == .off {
		warn_mcp_stdio_unsandboxed_default()
	} else if mode == .auto {
		eprintln('veasel: trusted MCP stdio falling back unsandboxed (VEASEL_MCP_STDIO_SANDBOX=auto but platform sandbox unavailable)')
	}
	mut process := os.new_process(server.command)
	process.set_args(args)
	process.set_work_folder(cwd)
	process.set_environment(env)
	process.set_redirect_stdio()
	process.run()
	if process.status != .running {
		process.close()
		return error('unable to start trusted Agent Plugin MCP server')
	}
	return &PluginMCPTransport{
		process: process
	}
}

// Windows AppContainer policy for trusted MCP stdio (opt-in via VEASEL_MCP_STDIO_SANDBOX):
// - separate VeaselTrustedMcp profile; PLUGIN_ROOT and PLUGIN_DATA ACL grants
// - network capability SIDs always enabled (many MCP servers need outbound HTTPS)
// - Job Object kill-on-close + process/memory caps; not Codex WFP/LPAC
// - missing AppContainer under auto falls back unsandboxed and never pretends sandboxed
fn start_plugin_mcp_transport_windows_sandboxed(root string, data string, cwd string, command string,
	args []string, env map[string]string) !&PluginMCPTransport {
	$if windows {
		mut sandboxed_env := env.clone()
		sandboxed_env['HOME'] = data
		sandboxed_env['USERPROFILE'] = data
		tmpdir := os.temp_dir()
		if tmpdir.len > 0 {
			sandboxed_env['TMP'] = tmpdir
			sandboxed_env['TEMP'] = tmpdir
			sandboxed_env['TMPDIR'] = tmpdir
		}
		win := start_windows_mcp_stdio_process(root, data, cwd, command, args, sandboxed_env)!
		return &PluginMCPTransport{
			win_mcp: voidptr(win)
		}
	} $else {
		return error('Windows MCP AppContainer wrap is unavailable on this platform')
	}
}

// macOS Seatbelt policy for trusted MCP stdio (opt-in via VEASEL_MCP_STDIO_SANDBOX):
// - sandbox-exec only from /usr/bin/sandbox-exec
// - default deny; host readable; writes limited to PLUGIN_ROOT, PLUGIN_DATA, and temp
// - /Users, /var/root, and /Volumes denied except PLUGIN_ROOT/PLUGIN_DATA carve-outs
// - network is shared (many MCP servers need outbound HTTPS); not a shell-style deny
// - missing sandbox-exec under auto falls back unsandboxed and never pretends sandboxed
fn macos_mcp_seatbelt_profile() string {
	return [
		'(version 1)',
		'(deny default)',
		'(allow process-exec)',
		'(allow process-fork)',
		'(allow signal (target self))',
		'(allow process-info* (target self))',
		'(allow sysctl-read)',
		'(allow mach-lookup (global-name "com.apple.system.opendirectoryd.libinfo"))',
		'(allow file-read-metadata)',
		'(allow file-read*)',
		'(allow file-write-data (require-all (literal "/dev/null") (vnode-type CHARACTER-DEVICE)))',
		'(allow file-write* (subpath (param "PLUGIN_ROOT")))',
		'(allow file-write* (subpath (param "PLUGIN_DATA")))',
		'(allow file-write* (subpath "/private/tmp"))',
		'(allow file-write* (subpath "/tmp"))',
		'(allow file-write* (subpath "/private/var/folders"))',
		'(allow file-write* (subpath "/var/folders"))',
		'(deny file-read* file-write* (require-all (subpath "/Users") (require-not (subpath (param "PLUGIN_ROOT"))) (require-not (subpath (param "PLUGIN_DATA")))))',
		'(deny file-read* file-write* (require-all (subpath "/var/root") (require-not (subpath (param "PLUGIN_ROOT"))) (require-not (subpath (param "PLUGIN_DATA")))))',
		'(deny file-read* file-write* (require-all (subpath "/private/var/root") (require-not (subpath (param "PLUGIN_ROOT"))) (require-not (subpath (param "PLUGIN_DATA")))))',
		'(deny file-read* file-write* (require-all (subpath "/Volumes") (require-not (subpath (param "PLUGIN_ROOT"))) (require-not (subpath (param "PLUGIN_DATA")))))',
		'(allow network-outbound)',
		'(allow network-inbound)',
		'(allow system-socket)',
	].join('\n')
}

fn start_plugin_mcp_transport_macos_sandboxed(root string, data string, cwd string, command string,
	args []string, env map[string]string) !&PluginMCPTransport {
	for broad_root in ['/', '/Users', '/System', '/Library', '/Applications', '/private', '/var',
		'/usr', '/bin', '/sbin', '/etc', '/tmp', '/Volumes', '/Network', '/dev', '/cores'] {
		if root == broad_root || data == broad_root {
			return error('Trusted MCP stdio refused: PLUGIN_ROOT or PLUGIN_DATA is too broad for the sandbox')
		}
	}
	if !seatbelt_available() {
		return error('Trusted MCP stdio could not locate /usr/bin/sandbox-exec')
	}
	profile := macos_mcp_seatbelt_profile()
	mut seatbelt_args := [
		'-p',
		profile,
		'-DPLUGIN_ROOT=${root}',
		'-DPLUGIN_DATA=${data}',
		'--',
		command,
	]
	for arg in args {
		seatbelt_args << arg
	}
	mut sandboxed_env := env.clone()
	sandboxed_env['HOME'] = data
	tmpdir := os.temp_dir()
	if tmpdir.len > 0 {
		sandboxed_env['TMPDIR'] = tmpdir
	}
	mut process := os.new_process(macos_seatbelt_executable)
	process.set_args(seatbelt_args)
	process.set_work_folder(cwd)
	process.set_environment(sandboxed_env)
	process.set_redirect_stdio()
	process.run()
	if process.status != .running {
		process.close()
		return error('unable to start trusted Agent Plugin MCP server inside Seatbelt')
	}
	return &PluginMCPTransport{
		process: process
	}
}

// Linux Bubblewrap policy for trusted MCP stdio (opt-in via VEASEL_MCP_STDIO_SANDBOX):
// - host root is read-only; PLUGIN_ROOT and PLUGIN_DATA are writable binds
// - home/runtime paths are masked; /tmp is a private tmpfs
// - network is shared (many MCP servers need outbound HTTPS); not a shell-style deny
// - missing bwrap under auto falls back unsandboxed and never pretends sandboxed
fn start_plugin_mcp_transport_linux_sandboxed(root string, data string, cwd string, command string,
	args []string, env map[string]string) !&PluginMCPTransport {
	for broad_root in ['/', '/home', '/root', '/tmp', '/usr', '/etc', '/var', '/opt'] {
		if root == broad_root || data == broad_root {
			return error('Trusted MCP stdio refused: PLUGIN_ROOT or PLUGIN_DATA is too broad for the sandbox')
		}
	}
	bwrap := bubblewrap_executable_path() or {
		return error('Trusted MCP stdio could not locate bubblewrap (bwrap)')
	}
	mut bwrap_args := [
		'--unshare-all',
		'--share-net',
		'--die-with-parent',
		'--new-session',
		'--ro-bind',
		'/',
		'/',
	]
	for hidden_path in ['/home', '/root', '/run', '/mnt', '/media', '/tmp'] {
		if os.is_dir(hidden_path) {
			bwrap_args << '--tmpfs'
			bwrap_args << hidden_path
		}
	}
	bwrap_args << '--proc'
	bwrap_args << '/proc'
	bwrap_args << '--dev'
	bwrap_args << '/dev'
	append_linux_bwrap_parent_dirs(mut bwrap_args, root)
	bwrap_args << '--bind'
	bwrap_args << root
	bwrap_args << root
	if data != root {
		append_linux_bwrap_parent_dirs(mut bwrap_args, data)
		bwrap_args << '--bind'
		bwrap_args << data
		bwrap_args << data
	}
	bwrap_args << '--chdir'
	bwrap_args << cwd
	bwrap_args << '--'
	bwrap_args << command
	for arg in args {
		bwrap_args << arg
	}
	mut sandboxed_env := env.clone()
	sandboxed_env['HOME'] = data
	sandboxed_env['TMPDIR'] = '/tmp'
	mut process := os.new_process(bwrap)
	process.set_args(bwrap_args)
	process.set_environment(sandboxed_env)
	process.set_redirect_stdio()
	process.run()
	if process.status != .running {
		process.close()
		return error('unable to start trusted Agent Plugin MCP server inside Bubblewrap')
	}
	return &PluginMCPTransport{
		process: process
	}
}

fn append_linux_bwrap_parent_dirs(mut args []string, path string) {
	mut parent := ''
	for component in path.split('/') {
		if component.len == 0 {
			continue
		}
		parent = if parent.len == 0 { '/${component}' } else { '${parent}/${component}' }
		if parent == path {
			break
		}
		args << '--dir'
		args << parent
	}
}

fn plugin_mcp_jsonrpc_request_id_json(message string) string {
	fields := json2.decode[map[string]json2.Any](message) or { return '' }
	id := fields['id'] or { return '' }
	method := fields['method'] or { return '' }
	if method is string && (method as string).starts_with('notifications/') {
		return ''
	}
	return json2.encode(id)
}

fn plugin_mcp_cancelled_notification(request_id_json string, reason string) string {
	safe_reason := reason.replace('\\', '\\\\').replace('"', '\\"')
	return '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":${request_id_json},"reason":"${safe_reason}"}}'
}

fn (mut transport PluginMCPTransport) request_cancel() {
	transport.cancel_requested = true
}

fn (transport &PluginMCPTransport) mcp_stdio_alive() bool {
	$if windows {
		if !isnil(transport.win_mcp) {
			win := unsafe { &WindowsMcpStdioProcess(transport.win_mcp) }
			return win.is_alive()
		}
	}
	if isnil(transport.process) {
		return false
	}
	return transport.process.is_alive()
}

fn (mut transport PluginMCPTransport) mcp_stdio_stdin_write(s string) {
	$if windows {
		if !isnil(transport.win_mcp) {
			mut win := unsafe { &WindowsMcpStdioProcess(transport.win_mcp) }
			win.stdin_write(s)
			return
		}
	}
	if !isnil(transport.process) {
		transport.process.stdin_write(s)
	}
}

fn (transport &PluginMCPTransport) mcp_stdio_pending_stdout() bool {
	$if windows {
		if !isnil(transport.win_mcp) {
			win := unsafe { &WindowsMcpStdioProcess(transport.win_mcp) }
			return win.is_pending_stdout()
		}
	}
	if isnil(transport.process) {
		return false
	}
	return transport.process.is_pending(.stdout)
}

fn (transport &PluginMCPTransport) mcp_stdio_pending_stderr() bool {
	$if windows {
		if !isnil(transport.win_mcp) {
			win := unsafe { &WindowsMcpStdioProcess(transport.win_mcp) }
			return win.is_pending_stderr()
		}
	}
	if isnil(transport.process) {
		return false
	}
	return transport.process.is_pending(.stderr)
}

fn (mut transport PluginMCPTransport) mcp_stdio_stdout_read() string {
	$if windows {
		if !isnil(transport.win_mcp) {
			mut win := unsafe { &WindowsMcpStdioProcess(transport.win_mcp) }
			return win.stdout_read()
		}
	}
	if isnil(transport.process) {
		return ''
	}
	return transport.process.stdout_read()
}

fn (mut transport PluginMCPTransport) mcp_stdio_stderr_read() string {
	$if windows {
		if !isnil(transport.win_mcp) {
			mut win := unsafe { &WindowsMcpStdioProcess(transport.win_mcp) }
			return win.stderr_read()
		}
	}
	if isnil(transport.process) {
		return ''
	}
	return transport.process.stderr_read()
}

fn (mut transport PluginMCPTransport) emit_cancelled_notification() {
	if transport.cancelled_notified || transport.active_request_id.len == 0 {
		return
	}
	if !transport.mcp_stdio_alive() {
		return
	}
	transport.cancelled_notified = true
	notification := plugin_mcp_cancelled_notification(transport.active_request_id, 'turn cancelled')
	if notification.len > max_plugin_mcp_frame_bytes {
		return
	}
	transport.mcp_stdio_stdin_write(notification + '\n')
}

// overlay_plugin_environment applies configured server variables onto the
// sanitized base. Windows environment names are case-insensitive, so a
// configured `Path` replaces an inherited `PATH` instead of leaving both.
fn overlay_plugin_environment(base map[string]string, configured map[string]string, case_insensitive bool) map[string]string {
	mut env := base.clone()
	for key, value in configured {
		if case_insensitive {
			mut remove := []string{}
			for existing, _ in env {
				if existing != key && existing.to_lower() == key.to_lower() {
					remove << existing
				}
			}
			for existing in remove {
				env.delete(existing)
			}
		}
		env[key] = value
	}
	return env
}

fn plugin_mcp_base_environment() map[string]string {
	mut env := map[string]string{}
	for key in ['PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'TMP', 'TEMP', 'LANG', 'LC_ALL',
		'SYSTEMROOT', 'WINDIR', 'PATHEXT', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'COMSPEC'] {
		if value := os.getenv_opt(key) {
			env[key] = value
		}
	}
	return env
}

fn (mut transport PluginMCPTransport) send(message string) ! {
	if message.len == 0 || message.len > max_plugin_mcp_frame_bytes {
		return error('MCP request exceeds the frame size limit')
	}
	if message.contains('\n') || message.contains('\r') {
		return error('MCP request contains invalid stdio framing')
	}
	if transport.cancel_requested {
		return error('cancelled')
	}
	request_id := plugin_mcp_jsonrpc_request_id_json(message)
	if request_id.len > 0 {
		transport.active_request_id = request_id
		transport.cancelled_notified = false
	}
	transport.mcp_stdio_stdin_write(message + '\n')
}

fn (mut transport PluginMCPTransport) receive() !string {
	started := time.now()
	for {
		if transport.cancel_requested {
			transport.emit_cancelled_notification()
			return error('cancelled')
		}
		if time.since(started) > transport.response_timeout {
			return error('MCP server response timed out')
		}
		if transport.mcp_stdio_pending_stderr() {
			_ := transport.mcp_stdio_stderr_read()
		}
		if transport.mcp_stdio_pending_stdout() {
			transport.buffer += transport.mcp_stdio_stdout_read()
			if transport.buffer.len > max_plugin_mcp_frame_bytes {
				return error('MCP response exceeds the frame size limit')
			}
			if newline := transport.buffer.index('\n') {
				frame := transport.buffer[..newline].trim_right('\r')
				transport.buffer = transport.buffer[newline + 1..]
				if frame.len == 0 {
					return error('MCP server returned an empty frame')
				}
				return frame
			}
		}
		if !transport.mcp_stdio_alive() {
			return error('MCP server exited before responding')
		}
		time.sleep(5 * time.millisecond)
	}
}

fn (mut transport PluginMCPTransport) close() {
	$if windows {
		if !isnil(transport.win_mcp) {
			mut win := unsafe { &WindowsMcpStdioProcess(transport.win_mcp) }
			if win.is_alive() {
				win.signal_kill()
				for _ in 0 .. 20 {
					if !win.is_alive() {
						break
					}
					time.sleep(10 * time.millisecond)
				}
			}
			win.close()
			transport.win_mcp = unsafe { nil }
			return
		}
	}
	if isnil(transport.process) {
		return
	}
	if transport.process.is_alive() {
		transport.process.signal_term()
		for _ in 0 .. 20 {
			if !transport.process.is_alive() {
				break
			}
			time.sleep(10 * time.millisecond)
		}
		if transport.process.is_alive() {
			transport.process.signal_kill()
		} else if transport.process.status in [.running, .stopped] {
			transport.process.wait()
		}
	}
	transport.process.close()
}

fn new_plugin_mcp_connection(plugin_root string, plugin_data string, server PluginMCPServer) !PluginMCPConnection {
	match server.transport {
		'stdio' {
			mut transport := start_plugin_mcp_transport(plugin_root, plugin_data, server)!
			return PluginMCPConnection{
				client:          mcp.new_client(transport, mcp.ClientConfig{})
				stdio_transport: transport
			}
		}
		'streamable-http' {
			return new_plugin_mcp_http_connection(server)!
		}
		else {
			return error('unsupported Agent Plugin MCP server')
		}
	}
}

fn new_plugin_mcp_client(plugin_root string, plugin_data string, server PluginMCPServer) !mcp.Client {
	connection := new_plugin_mcp_connection(plugin_root, plugin_data, server)!
	return connection.client
}

fn (app &App) load_session_plugin_mcp_tools(session_id string) !([]AgentToolDefinition, map[string]PluginMCPToolBinding, []PluginMCPConnection) {
	mut active := app.store.session_plugin_mcp_servers(session_id)!
	if active.len > max_session_plugin_mcp_servers {
		// Older databases may contain more entries than the current trust limit.
		// Keep chat usable and apply the deterministic store ordering.
		eprintln('veasel: only the first ${max_session_plugin_mcp_servers} trusted MCP servers will be loaded')
		active = active[..max_session_plugin_mcp_servers]
	}
	mut definitions := []AgentToolDefinition{}
	mut bindings := map[string]PluginMCPToolBinding{}
	mut connections := []PluginMCPConnection{}
	session := app.store.get_session(session_id) or {
		return error(err.msg())
	}
	for selected in active {
		plugin_root, server := app.find_session_mcp_server(selected.plugin_name, selected.server_name,
			session.directory) or {
			eprintln('veasel: trusted MCP server configuration is no longer available')
			continue
		}
		plugin_data := if selected.plugin_name == configured_mcp_plugin_name {
			app.configured_mcp_package_root(selected.server_name)
		} else {
			os.join_path(app.plugin_data_directory, selected.plugin_name)
		}
		mut connection := new_plugin_mcp_connection(plugin_root, plugin_data, server) or {
			eprintln('veasel: trusted MCP server could not be started')
			continue
		}
		// Attach OAuth refresh before initialize so a 401 can refresh once and
		// retry without dropping the trusted server for an expired Bearer.
		if !isnil(connection.http_transport) && server.credential.len > 0 {
			mut http_transport := connection.http_transport
			http_transport.attach_oauth_refresh(server.credential, app.mcp_oauth_refresh,
				app.mcp_credentials)
		}
		connection.client.initialize() or {
			eprintln('veasel: trusted MCP server initialization failed')
			connection.client.close()
			continue
		}
		// Best-effort Streamable HTTP GET notification stream. Failures are
		// non-fatal; notifications stay off the RPC pending queue.
		if !isnil(connection.http_transport) {
			mut http_transport := connection.http_transport
			_ := http_transport.listen_notifications() or { 0 }
		}
		connection_index := connections.len
		mut connection_has_tools := false
		mut cursor := ''
		mut seen_cursors := map[string]bool{}
		for page in 0 .. max_session_plugin_mcp_tool_pages {
			result := request_plugin_mcp_tool_page(mut connection.client, cursor) or {
				eprintln('veasel: trusted MCP server tool listing failed')
				break
			}
			tool_values := result['tools'] or { break }
			if tool_values !is []json2.Any {
				break
			}
			for value in tool_values as []json2.Any {
				if definitions.len >= max_session_plugin_mcp_tools {
					connection.client.close()
					close_plugin_mcp_connections(mut connections)
					return error('session exceeds the trusted MCP tool limit')
				}
				if value !is map[string]json2.Any {
					continue
				}
				fields := value as map[string]json2.Any
				native_name_value := fields['name'] or { continue }
				if native_name_value !is string {
					continue
				}
				native_name := native_name_value as string
				if native_name.len == 0 || native_name.len > 256 || native_name.contains('\0') {
					continue
				}
				schema_value := fields['inputSchema'] or { continue }
				schema := json2.encode[json2.Any](schema_value)
				if schema.len == 0 || schema.len > 64_000 {
					continue
				}
				parsed_schema := json2.decode[map[string]json2.Any](schema) or { continue }
				schema_type := parsed_schema['type'] or { continue }
				if schema_type !is string || schema_type as string != 'object' {
					continue
				}
				mut description := ''
				if desc := fields['description'] {
					if desc is string && desc.len <= 4_000 {
						description = desc as string
					}
				}
				provider_name := plugin_mcp_provider_name(selected.plugin_name,
					selected.server_name, native_name)
				if provider_name in bindings {
					continue
				}
				definitions << AgentToolDefinition{
					name:           provider_name
					description:    if description.len > 0 {
						'Untrusted plugin metadata: ' + description
					} else {
						'Untrusted MCP tool metadata.'
					}
					raw_parameters: schema
				}
				bindings[provider_name] = PluginMCPToolBinding{
					connection_index: connection_index
					native_name:      native_name
					plugin_name:      selected.plugin_name
					server_name:      selected.server_name
				}
				connection_has_tools = true
			}
			next_cursor_value := result['nextCursor'] or { break }
			if next_cursor_value !is string {
				eprintln('veasel: trusted MCP server returned an invalid tool cursor')
				break
			}
			next_cursor := next_cursor_value as string
			if next_cursor.len == 0 || next_cursor.len > max_session_plugin_mcp_cursor_bytes
				|| next_cursor.contains('\0') || seen_cursors[next_cursor] {
				eprintln('veasel: trusted MCP server returned an invalid tool cursor')
				break
			}
			if page == max_session_plugin_mcp_tool_pages - 1 {
				eprintln('veasel: trusted MCP server tool page limit reached')
				break
			}
			seen_cursors[next_cursor] = true
			cursor = next_cursor
		}
		if connection_has_tools {
			connections << connection
		} else {
			connection.client.close()
		}
	}
	return definitions, bindings, connections
}

fn request_plugin_mcp_tool_page(mut client mcp.Client, cursor string) !map[string]json2.Any {
	mut params := map[string]json2.Any{}
	if cursor.len > 0 {
		params['cursor'] = json2.Any(cursor)
	}
	response := client.request_message('tools/list', params)!
	if response.error.code != 0 || response.result.len > max_plugin_mcp_frame_bytes {
		return error('invalid or oversized MCP tool page')
	}
	return json2.decode[map[string]json2.Any](response.result) or {
		return error('MCP server returned invalid tool page JSON')
	}
}

fn close_plugin_mcp_connections(mut connections []PluginMCPConnection) {
	for index in 0 .. connections.len {
		connections[index].client.close()
	}
}

fn watch_plugin_mcp_stdio_cancel(mut turn_ctx vcontext.Context, transport &PluginMCPTransport,
	done chan int) {
	watch_plugin_mcp_cancel(mut turn_ctx, transport, unsafe { nil }, done)
}

fn watch_plugin_mcp_http_cancel(mut turn_ctx vcontext.Context, transport &PluginMCPHTTPTransport,
	done chan int) {
	watch_plugin_mcp_cancel(mut turn_ctx, unsafe { nil }, transport, done)
}

fn watch_plugin_mcp_cancel(mut turn_ctx vcontext.Context, stdio &PluginMCPTransport,
	http_transport &PluginMCPHTTPTransport, done chan int) {
	for {
		mut finished := 0
		if done.try_pop(mut finished) == .success {
			return
		}
		if context_error := turn_context_error(mut turn_ctx) {
			if context_error == 'cancelled' {
				if !isnil(stdio) {
					mut active := stdio
					active.request_cancel()
				}
				if !isnil(http_transport) {
					mut active_http := http_transport
					active_http.request_cancel()
				}
				return
			}
		}
		time.sleep(50 * time.millisecond)
	}
}

fn plugin_mcp_provider_name(plugin_name string, server_name string, native_name string) string {
	raw := 'mcp_${plugin_name}_${server_name}_${native_name}'
	mut builder := strings.new_builder(64)
	mut count := 0
	for c in raw {
		if count >= 48 {
			break
		}
		if c.is_alnum() || c == `_` || c == `-` {
			builder.write_u8(c)
		} else {
			builder.write_u8(`_`)
		}
		count++
	}
	hash := strconv.format_int(i64(raw.hash()), 16)
	return '${builder.str()}_${hash}'
}

fn execute_plugin_mcp_tool(mut connections []PluginMCPConnection, binding PluginMCPToolBinding,
	arguments string) string {
	if binding.connection_index < 0 || binding.connection_index >= connections.len {
		return '{"error":"MCP server connection is unavailable."}'
	}
	parsed_arguments := json2.decode[json2.Any](arguments) or {
		return '{"error":"MCP tool arguments are invalid."}'
	}
	if parsed_arguments !is map[string]json2.Any {
		return '{"error":"MCP tool arguments must be an object."}'
	}
	params := {
		'name':      json2.Any(binding.native_name)
		'arguments': parsed_arguments
	}
	response := connections[binding.connection_index].client.request_message('tools/call', params) or {
		return '{"error":"MCP tool call failed."}'
	}
	if response.error.code != 0 || response.result.len > max_agent_tool_result_bytes {
		return '{"error":"MCP tool returned an error or oversized result."}'
	}
	return response.result
}
