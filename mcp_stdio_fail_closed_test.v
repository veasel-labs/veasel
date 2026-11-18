module main

import os
import uuid

// Behavioural fail-closed tests for trusted MCP stdio (#746). They use only
// env strings so they can also run against the pre-fix code to show red.

const mcp_opt_in_env = 'VEASEL_SHELL_ALLOW_UNSANDBOXED'
const mcp_opt_in_token = 'i-accept-unsandboxed-shell-execution'

fn with_mcp_env(mode string, opt_in string, body fn ()) {
	prior_mode := os.getenv_opt('VEASEL_MCP_STDIO_SANDBOX')
	prior_opt := os.getenv_opt(mcp_opt_in_env)
	os.setenv('VEASEL_MCP_STDIO_SANDBOX', mode, true)
	if opt_in.len > 0 {
		os.setenv(mcp_opt_in_env, opt_in, true)
	} else {
		os.unsetenv(mcp_opt_in_env)
	}
	defer {
		if v := prior_mode {
			os.setenv('VEASEL_MCP_STDIO_SANDBOX', v, true)
		} else {
			os.unsetenv('VEASEL_MCP_STDIO_SANDBOX')
		}
		if v := prior_opt {
			os.setenv(mcp_opt_in_env, v, true)
		} else {
			os.unsetenv(mcp_opt_in_env)
		}
	}
	body()
}

fn mcp_fixture_dirs() (string, string) {
	root := os.join_path(os.temp_dir(), 'veasel-mcp-fc-${uuid.new_v4().str()}')
	data := '${root}-data'
	os.mkdir_all(root) or { panic(err) }
	os.mkdir_all(data) or { panic(err) }
	return root, data
}

fn mcp_try_start(root string, data string) !&PluginMCPTransport {
	return start_plugin_mcp_transport(root, data, PluginMCPServer{
		name:      'fc'
		transport: 'stdio'
		command:   '/bin/sleep'
		args:      ['30']
	})
}

fn test_mcp_stdio_off_without_opt_in_refuses_to_start() {
	root, data := mcp_fixture_dirs()
	defer {
		os.rmdir_all(root) or {}
		os.rmdir_all(data) or {}
	}
	with_mcp_env('off', '', fn [root, data] () {
		if mut transport := mcp_try_start(root, data) {
			transport.close()
			assert false, 'off without the opt-in must not start an unsandboxed MCP server'
		} else {
			assert err.msg().contains(mcp_opt_in_env)
		}
	})
}

fn test_mcp_stdio_off_with_wrong_token_refuses_to_start() {
	root, data := mcp_fixture_dirs()
	defer {
		os.rmdir_all(root) or {}
		os.rmdir_all(data) or {}
	}
	with_mcp_env('off', '1', fn [root, data] () {
		if mut transport := mcp_try_start(root, data) {
			transport.close()
			assert false
		}
	})
}

fn test_mcp_stdio_off_with_explicit_opt_in_still_starts() {
	root, data := mcp_fixture_dirs()
	defer {
		os.rmdir_all(root) or {}
		os.rmdir_all(data) or {}
	}
	with_mcp_env('off', mcp_opt_in_token, fn [root, data] () {
		mut transport := mcp_try_start(root, data) or { panic(err) }
		assert transport.mcp_stdio_alive()
		transport.close()
	})
}
