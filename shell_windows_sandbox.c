#include "shell_windows_sandbox.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#ifndef JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
#define JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE 0x00002000
#endif
#ifndef JOB_OBJECT_LIMIT_ACTIVE_PROCESS
#define JOB_OBJECT_LIMIT_ACTIVE_PROCESS 0x00000008
#endif
#ifndef JOB_OBJECT_LIMIT_JOB_MEMORY
#define JOB_OBJECT_LIMIT_JOB_MEMORY 0x00000200
#endif
#ifndef JobObjectExtendedLimitInformation
#define JobObjectExtendedLimitInformation 9
#endif
#ifndef DISABLE_MAX_PRIVILEGE
#define DISABLE_MAX_PRIVILEGE 0x1
#endif

enum {
	VEASEL_WIN_ACTIVE_PROCESS_LIMIT = 64,
	VEASEL_WIN_JOB_MEMORY_BYTES = 512 * 1024 * 1024
};

static void set_error(VeaselWinSandboxResult *result, const char *prefix, DWORD err) {
	if (!result) {
		return;
	}
	if (err == 0) {
		snprintf(result->error_message, sizeof(result->error_message), "%s", prefix);
	} else {
		snprintf(result->error_message, sizeof(result->error_message), "%s (Win32 %lu)", prefix,
			(unsigned long)err);
	}
}

static wchar_t *utf8_to_wide(const char *utf8) {
	int needed;
	wchar_t *wide;
	if (!utf8) {
		return NULL;
	}
	needed = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
	if (needed <= 0) {
		return NULL;
	}
	wide = (wchar_t *)malloc((size_t)needed * sizeof(wchar_t));
	if (!wide) {
		return NULL;
	}
	if (MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide, needed) <= 0) {
		free(wide);
		return NULL;
	}
	return wide;
}

static int append_quoted_arg(wchar_t *dest, size_t dest_cap, size_t *len, const wchar_t *arg) {
	size_t arg_len;
	size_t i;
	if (!dest || !len || !arg) {
		return 0;
	}
	arg_len = wcslen(arg);
	/* space + quotes + arg + NUL */
	if (*len + arg_len + 4 >= dest_cap) {
		return 0;
	}
	if (*len > 0) {
		dest[(*len)++] = L' ';
	}
	dest[(*len)++] = L'"';
	for (i = 0; i < arg_len; i++) {
		if (arg[i] == L'"') {
			if (*len + 2 >= dest_cap) {
				return 0;
			}
			dest[(*len)++] = L'\\';
		}
		dest[(*len)++] = arg[i];
	}
	dest[(*len)++] = L'"';
	dest[*len] = L'\0';
	return 1;
}

static int configure_job(HANDLE job) {
	JOBOBJECT_EXTENDED_LIMIT_INFORMATION info;
	ZeroMemory(&info, sizeof(info));
	info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
		| JOB_OBJECT_LIMIT_ACTIVE_PROCESS | JOB_OBJECT_LIMIT_JOB_MEMORY;
	info.BasicLimitInformation.ActiveProcessLimit = VEASEL_WIN_ACTIVE_PROCESS_LIMIT;
	info.JobMemoryLimit = (SIZE_T)VEASEL_WIN_JOB_MEMORY_BYTES;
	return SetInformationJobObject(job, JobObjectExtendedLimitInformation, &info, sizeof(info))
		? 1
		: 0;
}

static HANDLE try_restricted_primary_token(void) {
	HANDLE process_token = NULL;
	HANDLE restricted = NULL;
	HANDLE primary = NULL;
	if (!OpenProcessToken(GetCurrentProcess(),
			TOKEN_DUPLICATE | TOKEN_QUERY | TOKEN_ASSIGN_PRIMARY, &process_token)) {
		return NULL;
	}
	if (!CreateRestrictedToken(process_token, DISABLE_MAX_PRIVILEGE, 0, NULL, 0, NULL, 0, NULL,
			&restricted)) {
		CloseHandle(process_token);
		return NULL;
	}
	CloseHandle(process_token);
	if (!DuplicateTokenEx(restricted, TOKEN_ALL_ACCESS, NULL, SecurityIdentification, TokenPrimary,
			&primary)) {
		CloseHandle(restricted);
		return NULL;
	}
	CloseHandle(restricted);
	return primary;
}

static int read_available(HANDLE pipe, char *buffer, int capacity, int *written, int *limited) {
	DWORD avail = 0;
	DWORD got = 0;
	int space;
	if (!PeekNamedPipe(pipe, NULL, 0, NULL, &avail, NULL)) {
		return 1;
	}
	if (avail == 0) {
		return 1;
	}
	space = capacity - *written;
	if (space <= 0) {
		*limited = 1;
		return 1;
	}
	if ((int)avail > space) {
		avail = (DWORD)space;
		*limited = 1;
	}
	if (!ReadFile(pipe, buffer + *written, avail, &got, NULL)) {
		return 0;
	}
	*written += (int)got;
	return 1;
}

int veasel_win_sandbox_available(void) {
	HANDLE job = CreateJobObjectW(NULL, NULL);
	if (!job) {
		return 0;
	}
	if (!configure_job(job)) {
		CloseHandle(job);
		return 0;
	}
	CloseHandle(job);
	return 1;
}

void veasel_win_sandbox_result_free(VeaselWinSandboxResult *result) {
	if (!result) {
		return;
	}
	free(result->output);
	result->output = NULL;
	result->output_len = 0;
}

int veasel_win_run_job_sandboxed_shell(const char *comspec_utf8, const char *command_utf8,
	const char *workdir_utf8, int timeout_ms, int max_output_bytes, int allow_network,
	VeaselWinSandboxResult *result) {
	wchar_t *comspec = NULL;
	wchar_t *command = NULL;
	wchar_t *workdir = NULL;
	wchar_t *cmdline = NULL;
	wchar_t arg_d[] = L"/D";
	wchar_t arg_s[] = L"/S";
	wchar_t arg_c[] = L"/C";
	size_t cmdline_cap;
	size_t cmdline_len = 0;
	HANDLE job = NULL;
	HANDLE restricted_token = NULL;
	HANDLE stdout_read = NULL;
	HANDLE stdout_write = NULL;
	HANDLE stderr_read = NULL;
	HANDLE stderr_write = NULL;
	HANDLE stdin_read = NULL;
	HANDLE stdin_write = NULL;
	SECURITY_ATTRIBUTES sa;
	STARTUPINFOW si;
	PROCESS_INFORMATION pi;
	DWORD creation_flags;
	BOOL created = FALSE;
	DWORD wait_remaining;
	DWORD slice;
	DWORD wait_rc;
	DWORD exit_code = 1;
	char *output = NULL;
	int output_len = 0;
	int limited = 0;
	ULONGLONG start_ms;
	(void)allow_network;

	if (!result) {
		return 0;
	}
	ZeroMemory(result, sizeof(*result));
	if (!comspec_utf8 || !command_utf8 || !workdir_utf8 || timeout_ms <= 0 || max_output_bytes <= 0) {
		result->setup_failed = 1;
		set_error(result, "Windows Job Object sandbox received invalid arguments", 0);
		return 0;
	}

	comspec = utf8_to_wide(comspec_utf8);
	command = utf8_to_wide(command_utf8);
	workdir = utf8_to_wide(workdir_utf8);
	if (!comspec || !command || !workdir) {
		result->setup_failed = 1;
		set_error(result, "Windows Job Object sandbox could not convert paths to UTF-16",
			GetLastError());
		goto cleanup;
	}

	cmdline_cap = wcslen(comspec) + wcslen(command) + 64;
	cmdline = (wchar_t *)malloc(cmdline_cap * sizeof(wchar_t));
	if (!cmdline) {
		result->setup_failed = 1;
		set_error(result, "Windows Job Object sandbox out of memory building command line", 0);
		goto cleanup;
	}
	cmdline[0] = L'\0';
	if (!append_quoted_arg(cmdline, cmdline_cap, &cmdline_len, comspec)
		|| !append_quoted_arg(cmdline, cmdline_cap, &cmdline_len, arg_d)
		|| !append_quoted_arg(cmdline, cmdline_cap, &cmdline_len, arg_s)
		|| !append_quoted_arg(cmdline, cmdline_cap, &cmdline_len, arg_c)
		|| !append_quoted_arg(cmdline, cmdline_cap, &cmdline_len, command)) {
		result->setup_failed = 1;
		set_error(result, "Windows Job Object sandbox command line is too long", 0);
		goto cleanup;
	}

	job = CreateJobObjectW(NULL, NULL);
	if (!job) {
		result->setup_failed = 1;
		set_error(result, "CreateJobObjectW failed", GetLastError());
		goto cleanup;
	}
	if (!configure_job(job)) {
		result->setup_failed = 1;
		set_error(result, "SetInformationJobObject failed", GetLastError());
		goto cleanup;
	}

	ZeroMemory(&sa, sizeof(sa));
	sa.nLength = sizeof(sa);
	sa.bInheritHandle = TRUE;
	if (!CreatePipe(&stdout_read, &stdout_write, &sa, 65536)
		|| !SetHandleInformation(stdout_read, HANDLE_FLAG_INHERIT, 0)
		|| !CreatePipe(&stderr_read, &stderr_write, &sa, 65536)
		|| !SetHandleInformation(stderr_read, HANDLE_FLAG_INHERIT, 0)
		|| !CreatePipe(&stdin_read, &stdin_write, &sa, 4096)
		|| !SetHandleInformation(stdin_write, HANDLE_FLAG_INHERIT, 0)) {
		result->setup_failed = 1;
		set_error(result, "CreatePipe for sandboxed shell failed", GetLastError());
		goto cleanup;
	}
	/* Non-interactive stdin: close the write end so reads see EOF. */
	CloseHandle(stdin_write);
	stdin_write = NULL;

	output = (char *)malloc((size_t)max_output_bytes + 1);
	if (!output) {
		result->setup_failed = 1;
		set_error(result, "Windows Job Object sandbox out of memory for output", 0);
		goto cleanup;
	}

	restricted_token = try_restricted_primary_token();

	ZeroMemory(&si, sizeof(si));
	si.cb = sizeof(si);
	si.dwFlags = STARTF_USESTDHANDLES;
	si.hStdInput = stdin_read;
	si.hStdOutput = stdout_write;
	si.hStdError = stderr_write;
	ZeroMemory(&pi, sizeof(pi));

	creation_flags = CREATE_UNICODE_ENVIRONMENT | CREATE_NEW_PROCESS_GROUP | CREATE_SUSPENDED
		| CREATE_NO_WINDOW;

	if (restricted_token) {
		created = CreateProcessAsUserW(restricted_token, NULL, cmdline, NULL, NULL, TRUE,
			creation_flags, NULL, workdir, &si, &pi);
		if (created) {
			result->used_restricted_token = 1;
		} else {
			CloseHandle(restricted_token);
			restricted_token = NULL;
		}
	}
	if (!created) {
		created = CreateProcessW(NULL, cmdline, NULL, NULL, TRUE, creation_flags, NULL, workdir, &si,
			&pi);
	}
	if (!created) {
		result->setup_failed = 1;
		set_error(result, "CreateProcess for Job Object sandbox failed", GetLastError());
		goto cleanup;
	}

	CloseHandle(stdout_write);
	stdout_write = NULL;
	CloseHandle(stderr_write);
	stderr_write = NULL;
	CloseHandle(stdin_read);
	stdin_read = NULL;

	if (!AssignProcessToJobObject(job, pi.hProcess)) {
		TerminateProcess(pi.hProcess, 1);
		WaitForSingleObject(pi.hProcess, 5000);
		result->setup_failed = 1;
		set_error(result, "AssignProcessToJobObject failed", GetLastError());
		goto cleanup_process;
	}
	if (ResumeThread(pi.hThread) == (DWORD)-1) {
		TerminateJobObject(job, 1);
		result->setup_failed = 1;
		set_error(result, "ResumeThread failed", GetLastError());
		goto cleanup_process;
	}

	start_ms = GetTickCount64();
	for (;;) {
		ULONGLONG elapsed = GetTickCount64() - start_ms;
		if (elapsed >= (ULONGLONG)timeout_ms) {
			result->timed_out = 1;
			TerminateJobObject(job, 1);
			break;
		}
		wait_remaining = timeout_ms - (DWORD)elapsed;
		slice = wait_remaining > 20 ? 20 : wait_remaining;
		wait_rc = WaitForSingleObject(pi.hProcess, slice);
		if (!read_available(stdout_read, output, max_output_bytes, &output_len, &limited)
			|| !read_available(stderr_read, output, max_output_bytes, &output_len, &limited)) {
			/* ignore read races while process exits */
		}
		if (limited) {
			result->output_limited = 1;
			TerminateJobObject(job, 1);
			break;
		}
		if (wait_rc == WAIT_OBJECT_0) {
			break;
		}
	}

	WaitForSingleObject(pi.hProcess, 5000);
	GetExitCodeProcess(pi.hProcess, &exit_code);
	read_available(stdout_read, output, max_output_bytes, &output_len, &limited);
	read_available(stderr_read, output, max_output_bytes, &output_len, &limited);
	if (limited) {
		result->output_limited = 1;
	}
	output[output_len] = '\0';
	result->ok = 1;
	result->exit_code = (int)exit_code;
	result->output = output;
	result->output_len = output_len;
	output = NULL;

cleanup_process:
	if (pi.hThread) {
		CloseHandle(pi.hThread);
		pi.hThread = NULL;
	}
	if (pi.hProcess) {
		CloseHandle(pi.hProcess);
		pi.hProcess = NULL;
	}

cleanup:
	if (restricted_token) {
		CloseHandle(restricted_token);
	}
	if (job) {
		CloseHandle(job);
	}
	if (stdout_write) {
		CloseHandle(stdout_write);
	}
	if (stdout_read) {
		CloseHandle(stdout_read);
	}
	if (stderr_write) {
		CloseHandle(stderr_write);
	}
	if (stderr_read) {
		CloseHandle(stderr_read);
	}
	if (stdin_write) {
		CloseHandle(stdin_write);
	}
	if (stdin_read) {
		CloseHandle(stdin_read);
	}
	free(output);
	free(cmdline);
	free(comspec);
	free(command);
	free(workdir);
	return result->ok ? 1 : 0;
}
