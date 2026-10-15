/* Veasel Windows AppContainer + Job Object sandbox (C helper).
 *
 * Approved shell:
 * - AppContainer token via CreateAppContainerProfile / SECURITY_CAPABILITIES
 * - Workspace directory ACL grant for the AppContainer SID (sibling paths stay denied)
 * - Network denied by default (no internetClient / privateNetwork capabilities);
 *   VEASEL_SHELL_SANDBOX_NETWORK=allow adds those capability SIDs
 * - Job Object: kill-on-job-close, active-process cap, job memory cap; no breakaway
 * - CREATE_SUSPENDED → AssignProcessToJobObject → ResumeThread
 *
 * Trusted MCP stdio (opt-in VEASEL_MCP_STDIO_SANDBOX):
 * - Separate AppContainer profile (VeaselTrustedMcp)
 * - ACL grant on PLUGIN_ROOT and PLUGIN_DATA (sibling paths stay denied)
 * - Network capability SIDs always enabled (many MCP servers need outbound HTTPS)
 * - Same Job Object limits; long-lived stdio pipes returned to the caller
 *
 * Residual gaps: inherited environment may carry credentials; system paths that
 * already allow ALL APPLICATION PACKAGES remain readable/executable; not a VM;
 * not Codex-level WFP helper-service / private-logon isolation / LPAC.
 */
#ifndef VEASEL_SHELL_WINDOWS_SANDBOX_H
#define VEASEL_SHELL_WINDOWS_SANDBOX_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VeaselWinSandboxResult {
	int ok;
	int setup_failed;
	int timed_out;
	int output_limited;
	int exit_code;
	int used_appcontainer;
	int used_job_object;
	int output_len;
	char *output;
	char error_message[512];
} VeaselWinSandboxResult;

/* Long-lived AppContainer MCP stdio process. Caller owns IO until close. */
typedef struct VeaselWinMcpStdio {
	int ok;
	int setup_failed;
	int used_appcontainer;
	int used_job_object;
	unsigned long pid;
	void *process_handle;
	void *thread_handle;
	void *job_handle;
	void *stdin_write;
	void *stdout_read;
	void *stderr_read;
	char error_message[512];
} VeaselWinMcpStdio;

/* True when AppContainer profile + Job Object limits can be created. */
int veasel_win_sandbox_available(void);

int veasel_win_run_sandboxed_shell(const char *comspec_utf8, const char *command_utf8,
	const char *workdir_utf8, int timeout_ms, int max_output_bytes, int allow_network,
	VeaselWinSandboxResult *result);

void veasel_win_sandbox_result_free(VeaselWinSandboxResult *result);

/* Start trusted MCP stdio inside AppContainer + Job. env_utf8 is a double-NUL
 * terminated list of KEY=VALUE entries (NULL inherits the parent environment).
 * Network capability SIDs are always granted. */
int veasel_win_mcp_stdio_start(const char *exe_utf8, const char *const *args_utf8, int argc,
	const char *workdir_utf8, const char *plugin_root_utf8, const char *plugin_data_utf8,
	const char *env_utf8, VeaselWinMcpStdio *out);

int veasel_win_mcp_stdio_is_alive(VeaselWinMcpStdio *proc);
int veasel_win_mcp_stdio_write_stdin(VeaselWinMcpStdio *proc, const char *data, int len);
/* which: 1 = stdout, 2 = stderr */
int veasel_win_mcp_stdio_pending(VeaselWinMcpStdio *proc, int which);
int veasel_win_mcp_stdio_read(VeaselWinMcpStdio *proc, int which, char *buf, int cap,
	int *out_len);
void veasel_win_mcp_stdio_terminate(VeaselWinMcpStdio *proc);
void veasel_win_mcp_stdio_close(VeaselWinMcpStdio *proc);

#ifdef __cplusplus
}
#endif

#endif
