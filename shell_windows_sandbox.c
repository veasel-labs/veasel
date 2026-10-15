#include "shell_windows_sandbox.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <userenv.h>
#include <aclapi.h>
#include <sddl.h>
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
#ifndef PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES
#define PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES 0x00020009
#endif
#ifndef PROC_THREAD_ATTRIBUTE_HANDLE_LIST
#define PROC_THREAD_ATTRIBUTE_HANDLE_LIST 0x00020002
#endif
/* Well-known capability SIDs (winnt.h); define if the toolchain headers lag. */
#ifndef WinCapabilityInternetClientSid
#define WinCapabilityInternetClientSid ((WELL_KNOWN_SID_TYPE)85)
#endif
#ifndef WinCapabilityInternetClientServerSid
#define WinCapabilityInternetClientServerSid ((WELL_KNOWN_SID_TYPE)86)
#endif
#ifndef WinCapabilityPrivateNetworkClientServerSid
#define WinCapabilityPrivateNetworkClientServerSid ((WELL_KNOWN_SID_TYPE)87)
#endif

enum {
	VEASEL_WIN_ACTIVE_PROCESS_LIMIT = 64,
	VEASEL_WIN_JOB_MEMORY_BYTES = 512 * 1024 * 1024
};

static const wchar_t *veasel_appcontainer_name = L"VeaselApprovedShell";
static const wchar_t *veasel_appcontainer_display = L"Veasel Approved Shell";
static const wchar_t *veasel_appcontainer_desc = L"Veasel approved-shell AppContainer sandbox";

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

static int append_raw_arg(wchar_t *dest, size_t dest_cap, size_t *len, const wchar_t *arg) {
	size_t arg_len;
	if (!dest || !len || !arg) {
		return 0;
	}
	arg_len = wcslen(arg);
	if (*len + arg_len + 2 >= dest_cap) {
		return 0;
	}
	if (*len > 0) {
		dest[(*len)++] = L' ';
	}
	memcpy(dest + *len, arg, arg_len * sizeof(wchar_t));
	*len += arg_len;
	dest[*len] = L'\0';
	return 1;
}

static int append_quoted_arg(wchar_t *dest, size_t dest_cap, size_t *len, const wchar_t *arg) {
	size_t arg_len;
	size_t i;
	if (!dest || !len || !arg) {
		return 0;
	}
	arg_len = wcslen(arg);
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

static PSID obtain_appcontainer_sid(void) {
	PSID sid = NULL;
	HRESULT hr = CreateAppContainerProfile(veasel_appcontainer_name, veasel_appcontainer_display,
		veasel_appcontainer_desc, NULL, 0, &sid);
	if (SUCCEEDED(hr) && sid) {
		return sid;
	}
	if (HRESULT_CODE(hr) == ERROR_ALREADY_EXISTS) {
		sid = NULL;
		hr = DeriveAppContainerSidFromAppContainerName(veasel_appcontainer_name, &sid);
		if (SUCCEEDED(hr) && sid) {
			return sid;
		}
	}
	return NULL;
}

static void free_capability_list(SID_AND_ATTRIBUTES *caps, DWORD count) {
	DWORD i;
	if (!caps) {
		return;
	}
	for (i = 0; i < count; i++) {
		free(caps[i].Sid);
		caps[i].Sid = NULL;
	}
	free(caps);
}

static int build_security_capabilities(PSID appcontainer_sid, int allow_network,
	SECURITY_CAPABILITIES *out_sc, SID_AND_ATTRIBUTES **out_caps) {
	WELL_KNOWN_SID_TYPE wanted[3];
	DWORD wanted_count = 0;
	SID_AND_ATTRIBUTES *caps = NULL;
	DWORD i;
	DWORD sid_size;

	ZeroMemory(out_sc, sizeof(*out_sc));
	*out_caps = NULL;
	if (!appcontainer_sid) {
		return 0;
	}
	if (allow_network) {
		wanted[wanted_count++] = WinCapabilityInternetClientSid;
		wanted[wanted_count++] = WinCapabilityInternetClientServerSid;
		wanted[wanted_count++] = WinCapabilityPrivateNetworkClientServerSid;
	}
	if (wanted_count > 0) {
		caps = (SID_AND_ATTRIBUTES *)calloc(wanted_count, sizeof(SID_AND_ATTRIBUTES));
		if (!caps) {
			return 0;
		}
		for (i = 0; i < wanted_count; i++) {
			sid_size = SECURITY_MAX_SID_SIZE;
			caps[i].Sid = (PSID)malloc(SECURITY_MAX_SID_SIZE);
			if (!caps[i].Sid) {
				free_capability_list(caps, wanted_count);
				return 0;
			}
			if (!CreateWellKnownSid(wanted[i], NULL, caps[i].Sid, &sid_size)) {
				free_capability_list(caps, wanted_count);
				return 0;
			}
			caps[i].Attributes = SE_GROUP_ENABLED;
		}
	}
	out_sc->AppContainerSid = appcontainer_sid;
	out_sc->Capabilities = caps;
	out_sc->CapabilityCount = wanted_count;
	*out_caps = caps;
	return 1;
}

static int grant_named_access(PSID appcontainer_sid, const wchar_t *path_utf16, DWORD access_mask,
	DWORD inheritance) {
	EXPLICIT_ACCESS_W explicit_access;
	PACL original_acl = NULL;
	PACL new_acl = NULL;
	PSECURITY_DESCRIPTOR sd = NULL;
	DWORD status;
	int ok = 0;

	if (!appcontainer_sid || !path_utf16) {
		return 0;
	}
	ZeroMemory(&explicit_access, sizeof(explicit_access));
	explicit_access.grfAccessMode = GRANT_ACCESS;
	explicit_access.grfAccessPermissions = access_mask;
	explicit_access.grfInheritance = inheritance;
	explicit_access.Trustee.TrusteeForm = TRUSTEE_IS_SID;
	explicit_access.Trustee.TrusteeType = TRUSTEE_IS_GROUP;
	explicit_access.Trustee.ptstrName = (LPWSTR)appcontainer_sid;

	status = GetNamedSecurityInfoW(path_utf16, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, NULL, NULL,
		&original_acl, NULL, &sd);
	if (status != ERROR_SUCCESS) {
		return 0;
	}
	status = SetEntriesInAclW(1, &explicit_access, original_acl, &new_acl);
	if (status != ERROR_SUCCESS) {
		LocalFree(sd);
		return 0;
	}
	status = SetNamedSecurityInfoW((LPWSTR)path_utf16, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, NULL,
		NULL, new_acl, NULL);
	if (status == ERROR_SUCCESS) {
		ok = 1;
	}
	if (new_acl) {
		LocalFree(new_acl);
	}
	if (sd) {
		LocalFree(sd);
	}
	return ok;
}

/* Grant workspace R/W plus execute-only traverse on each parent so CreateProcess
 * can open the working directory without opening sibling trees for write. */
static int grant_workspace_access(PSID appcontainer_sid, const wchar_t *workdir_utf16) {
	wchar_t *path = NULL;
	size_t len;
	wchar_t *slash;
	if (!grant_named_access(appcontainer_sid, workdir_utf16,
			GENERIC_READ | GENERIC_WRITE | GENERIC_EXECUTE | DELETE,
			OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE)) {
		return 0;
	}
	len = wcslen(workdir_utf16);
	path = (wchar_t *)malloc((len + 1) * sizeof(wchar_t));
	if (!path) {
		return 0;
	}
	memcpy(path, workdir_utf16, (len + 1) * sizeof(wchar_t));
	for (;;) {
		slash = wcsrchr(path, L'\\');
		if (!slash) {
			slash = wcsrchr(path, L'/');
		}
		if (!slash || slash == path) {
			break;
		}
		/* Keep "C:\" as volume root; stop before stripping the drive. */
		if (slash <= path + 2 && path[1] == L':') {
			break;
		}
		*slash = L'\0';
		if (wcslen(path) == 0) {
			break;
		}
		if (!grant_named_access(appcontainer_sid, path, GENERIC_EXECUTE, 0)) {
			/* Parent may already allow ALL APPLICATION PACKAGES; continue. */
		}
	}
	free(path);
	return 1;
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
	PSID sid = NULL;
	HANDLE job = NULL;
	int ok = 0;

	sid = obtain_appcontainer_sid();
	if (!sid) {
		return 0;
	}
	job = CreateJobObjectW(NULL, NULL);
	if (!job) {
		FreeSid(sid);
		return 0;
	}
	if (configure_job(job)) {
		ok = 1;
	}
	CloseHandle(job);
	FreeSid(sid);
	return ok;
}

void veasel_win_sandbox_result_free(VeaselWinSandboxResult *result) {
	if (!result) {
		return;
	}
	free(result->output);
	result->output = NULL;
	result->output_len = 0;
}

int veasel_win_run_sandboxed_shell(const char *comspec_utf8, const char *command_utf8,
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
	PSID appcontainer_sid = NULL;
	SID_AND_ATTRIBUTES *capability_sids = NULL;
	SECURITY_CAPABILITIES security_capabilities;
	SIZE_T attr_size = 0;
	LPPROC_THREAD_ATTRIBUTE_LIST attr_list = NULL;
	HANDLE inherited_handles[3];
	HANDLE job = NULL;
	HANDLE stdout_read = NULL;
	HANDLE stdout_write = NULL;
	HANDLE stderr_read = NULL;
	HANDLE stderr_write = NULL;
	HANDLE stdin_read = NULL;
	HANDLE stdin_write = NULL;
	SECURITY_ATTRIBUTES sa;
	STARTUPINFOEXW siex;
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

	if (!result) {
		return 0;
	}
	ZeroMemory(result, sizeof(*result));
	ZeroMemory(&security_capabilities, sizeof(security_capabilities));
	ZeroMemory(&siex, sizeof(siex));
	ZeroMemory(&pi, sizeof(pi));
	if (!comspec_utf8 || !command_utf8 || !workdir_utf8 || timeout_ms <= 0 || max_output_bytes <= 0) {
		result->setup_failed = 1;
		set_error(result, "Windows AppContainer sandbox received invalid arguments", 0);
		return 0;
	}

	comspec = utf8_to_wide(comspec_utf8);
	command = utf8_to_wide(command_utf8);
	workdir = utf8_to_wide(workdir_utf8);
	if (!comspec || !command || !workdir) {
		result->setup_failed = 1;
		set_error(result, "Windows AppContainer sandbox could not convert paths to UTF-16",
			GetLastError());
		goto cleanup;
	}

	appcontainer_sid = obtain_appcontainer_sid();
	if (!appcontainer_sid) {
		result->setup_failed = 1;
		set_error(result, "CreateAppContainerProfile/DeriveAppContainerSid failed", GetLastError());
		goto cleanup;
	}
	if (!build_security_capabilities(appcontainer_sid, allow_network, &security_capabilities,
			&capability_sids)) {
		result->setup_failed = 1;
		set_error(result, "Failed to build AppContainer SECURITY_CAPABILITIES", GetLastError());
		goto cleanup;
	}
	/* Workspace must be explicitly readable/writable for the AppContainer SID. */
	if (!grant_workspace_access(appcontainer_sid, workdir)) {
		result->setup_failed = 1;
		set_error(result, "Failed to grant AppContainer ACL on workspace", GetLastError());
		goto cleanup;
	}

	cmdline_cap = wcslen(comspec) + wcslen(command) + 64;
	cmdline = (wchar_t *)malloc(cmdline_cap * sizeof(wchar_t));
	if (!cmdline) {
		result->setup_failed = 1;
		set_error(result, "Windows AppContainer sandbox out of memory building command line", 0);
		goto cleanup;
	}
	/* cmd.exe expects: "comspec" /D /S /C "command". Quoting /D /S /C breaks
	 * /S quote stripping and yields errors like '"echo …' is not recognized. */
	cmdline[0] = L'\0';
	if (!append_quoted_arg(cmdline, cmdline_cap, &cmdline_len, comspec)
		|| !append_raw_arg(cmdline, cmdline_cap, &cmdline_len, arg_d)
		|| !append_raw_arg(cmdline, cmdline_cap, &cmdline_len, arg_s)
		|| !append_raw_arg(cmdline, cmdline_cap, &cmdline_len, arg_c)
		|| !append_quoted_arg(cmdline, cmdline_cap, &cmdline_len, command)) {
		result->setup_failed = 1;
		set_error(result, "Windows AppContainer sandbox command line is too long", 0);
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
	CloseHandle(stdin_write);
	stdin_write = NULL;

	output = (char *)malloc((size_t)max_output_bytes + 1);
	if (!output) {
		result->setup_failed = 1;
		set_error(result, "Windows AppContainer sandbox out of memory for output", 0);
		goto cleanup;
	}

	/* AppContainer processes inherit only handles listed here, even when
	 * bInheritHandles is TRUE — without HANDLE_LIST, stdout/stderr pipes are
	 * silent and tests see empty or garbled capture. */
	InitializeProcThreadAttributeList(NULL, 2, 0, &attr_size);
	attr_list = (LPPROC_THREAD_ATTRIBUTE_LIST)malloc(attr_size);
	if (!attr_list) {
		result->setup_failed = 1;
		set_error(result, "Out of memory for PROC_THREAD_ATTRIBUTE_LIST", 0);
		goto cleanup;
	}
	if (!InitializeProcThreadAttributeList(attr_list, 2, 0, &attr_size)) {
		result->setup_failed = 1;
		set_error(result, "InitializeProcThreadAttributeList failed", GetLastError());
		goto cleanup;
	}
	inherited_handles[0] = stdin_read;
	inherited_handles[1] = stdout_write;
	inherited_handles[2] = stderr_write;
	if (!UpdateProcThreadAttribute(attr_list, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
			inherited_handles, sizeof(inherited_handles), NULL, NULL)) {
		result->setup_failed = 1;
		set_error(result, "UpdateProcThreadAttribute HANDLE_LIST failed", GetLastError());
		goto cleanup;
	}
	if (!UpdateProcThreadAttribute(attr_list, 0, PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES,
			&security_capabilities, sizeof(security_capabilities), NULL, NULL)) {
		result->setup_failed = 1;
		set_error(result, "UpdateProcThreadAttribute SECURITY_CAPABILITIES failed", GetLastError());
		goto cleanup;
	}

	siex.StartupInfo.cb = sizeof(siex);
	siex.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
	siex.StartupInfo.hStdInput = stdin_read;
	siex.StartupInfo.hStdOutput = stdout_write;
	siex.StartupInfo.hStdError = stderr_write;
	siex.lpAttributeList = attr_list;

	creation_flags = CREATE_UNICODE_ENVIRONMENT | CREATE_NEW_PROCESS_GROUP | CREATE_SUSPENDED
		| CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT;

	created = CreateProcessW(NULL, cmdline, NULL, NULL, TRUE, creation_flags, NULL, workdir,
		&siex.StartupInfo, &pi);
	if (!created) {
		result->setup_failed = 1;
		set_error(result, "CreateProcess AppContainer sandbox failed", GetLastError());
		goto cleanup;
	}
	result->used_appcontainer = 1;

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
	result->used_job_object = 1;
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
	if (attr_list) {
		DeleteProcThreadAttributeList(attr_list);
		free(attr_list);
	}
	free_capability_list(capability_sids, security_capabilities.CapabilityCount);
	if (appcontainer_sid) {
		FreeSid(appcontainer_sid);
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
