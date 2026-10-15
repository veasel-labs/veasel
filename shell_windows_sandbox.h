/* Veasel Windows approved-shell AppContainer + Job Object sandbox (C helper).
 *
 * Guarantees (honest):
 * - AppContainer token via CreateAppContainerProfile / SECURITY_CAPABILITIES
 * - Workspace directory ACL grant for the AppContainer SID (sibling paths stay denied)
 * - Network denied by default (no internetClient / privateNetwork capabilities);
 *   VEASEL_SHELL_SANDBOX_NETWORK=allow adds those capability SIDs
 * - Job Object: kill-on-job-close, active-process cap, job memory cap; no breakaway
 * - CREATE_SUSPENDED → AssignProcessToJobObject → ResumeThread
 *
 * Residual gaps: inherited environment may carry credentials; system paths that
 * already allow ALL APPLICATION PACKAGES remain readable/executable; not a VM;
 * not Codex-level WFP helper-service / private-logon isolation.
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

/* True when AppContainer profile + Job Object limits can be created. */
int veasel_win_sandbox_available(void);

int veasel_win_run_sandboxed_shell(const char *comspec_utf8, const char *command_utf8,
	const char *workdir_utf8, int timeout_ms, int max_output_bytes, int allow_network,
	VeaselWinSandboxResult *result);

void veasel_win_sandbox_result_free(VeaselWinSandboxResult *result);

#ifdef __cplusplus
}
#endif

#endif
