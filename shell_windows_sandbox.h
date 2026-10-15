/* Veasel Windows approved-shell Job Object sandbox (C helper).
 *
 * Guarantees (honest): process-tree containment via Job Object limits
 * (kill-on-job-close, active process cap, job memory cap) plus best-effort
 * DISABLE_MAX_PRIVILEGE restricted token when CreateProcessAsUser succeeds.
 * Does NOT provide AppContainer filesystem/network isolation, WFP filtering,
 * or workspace-only writes. Network isolation is not implemented; allow_network
 * is accepted for API symmetry and ignored.
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
	int used_restricted_token;
	int output_len;
	char *output;
	char error_message[512];
} VeaselWinSandboxResult;

int veasel_win_sandbox_available(void);

int veasel_win_run_job_sandboxed_shell(const char *comspec_utf8, const char *command_utf8,
	const char *workdir_utf8, int timeout_ms, int max_output_bytes, int allow_network,
	VeaselWinSandboxResult *result);

void veasel_win_sandbox_result_free(VeaselWinSandboxResult *result);

#ifdef __cplusplus
}
#endif

#endif
