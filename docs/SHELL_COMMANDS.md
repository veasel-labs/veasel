# Reviewed shell commands

When a coding task needs an external command, the agent can create a stored
proposal. Proposal creation never starts a process. The TUI exposes it through
`/commands`; `/command show <id>` opens the exact command, workspace-relative
working directory, and timeout. Only `/command approve <id>` starts it, while
`/command reject <id>` records a rejection.

Approval is one-time and durable. Veasel changes the proposal to `running` and
records the approval event before it launches the shell. Afterward it stores the
exit code, bounded output, and outcome. A server restart that finds a `running`
record changes it to `uncertain`; it never launches the command again. Inspect
the workspace and any external effects before continuing after an uncertain
result.

During graceful server shutdown, Veasel stops accepting new approvals and waits
for already approved commands to finish, subject to their configured timeout.
If the server is forcibly terminated, a running child may outlive the server;
its persisted state is `uncertain` at the next startup and it is not replayed.

Manually approved commands use `/bin/sh -c` on POSIX systems and `%COMSPEC% /D
/S /C` on Windows. Standard input is non-interactive. Approval remains the
authorization gate; OS sandboxing is defense-in-depth containment, not a bypass
of review.

## Shared configuration

| Variable | Values | Behavior |
|---|---|---|
| `VEASEL_SHELL_SANDBOX` | `auto` (default), `off`, `require` | Wrap when the platform backend is available; never wrap; or fail closed if wrap cannot run |
| `VEASEL_SHELL_SANDBOX_NETWORK` | unset/deny (default), `allow` | Whether the platform sandbox may share host network |

Capability flags are advertised only when that platform will actually wrap:

| Capability | When true |
|---|---|
| `shell.sandbox.bubblewrap` | Linux, mode not `off`, and `bwrap` on `PATH` |
| `shell.sandbox.seatbelt` | macOS, mode not `off`, and `/usr/bin/sandbox-exec` present |
| `shell.sandbox.windows` | Windows, mode not `off`, and AppContainer + Job Object wrap can be created |

Under `require`, missing backends fail closed with no unsandboxed fallback.
Under `auto`, missing backends fall through unsandboxed and do **not**
advertise a sandbox capability.

## Linux Bubblewrap for approved commands

On Linux, when `bwrap` is on `PATH` and `VEASEL_SHELL_SANDBOX` is not `off`,
approved commands run inside Bubblewrap with this default policy:

| Control | Default |
|---|---|
| Host filesystem | Read-only bind of `/` |
| Workspace | Writable bind of the session workspace only |
| Hidden mounts | tmpfs over `/home`, `/root`, `/run`, `/mnt`, `/media`, and `/tmp` when present |
| Namespaces | `--unshare-all` (no host network by default) |
| Network | Denied unless `VEASEL_SHELL_SANDBOX_NETWORK=allow` (adds `--share-net`) |
| Environment | Inherited from the Veasel process, with `HOME`/`TMPDIR` remapped to `/tmp` |
| Capability flag | `shell.sandbox.bubblewrap` |

This is best-effort containment, not a VM. Host-readable files outside the
masked paths can still be read; pre-existing hard links inside the workspace can
refer to host inodes; inherited environment variables may still carry
credentials.

## macOS Seatbelt for approved commands

On macOS, when `/usr/bin/sandbox-exec` exists and `VEASEL_SHELL_SANDBOX` is not
`off`, approved commands run under a Seatbelt profile with this default policy:

| Control | Default |
|---|---|
| Host filesystem | Readable |
| Workspace | Writable via `(subpath (param "WORKSPACE"))` |
| Temp writes | Allowed under `/tmp`, `/private/tmp`, and `/var/folders` |
| Restricted paths | Deny read/write under `/Users`, `/var/root`, and `/Volumes` except the workspace carve-out |
| Network | Denied unless `VEASEL_SHELL_SANDBOX_NETWORK=allow` |
| Executable | Only `/usr/bin/sandbox-exec` (never a PATH lookup) |
| Capability flag | `shell.sandbox.seatbelt` |

Seatbelt via `sandbox-exec` is best-effort and may be constrained or deprecated
by future macOS releases. It is not a VM. Inherited environment may still carry
credentials. See [`compatibility/shell-seatbelt-sandbox.md`](compatibility/shell-seatbelt-sandbox.md).

## Windows AppContainer + Job Object for approved commands

On Windows, when an AppContainer profile and Job Object can be created and
`VEASEL_SHELL_SANDBOX` is not `off`, approved commands run through `%COMSPEC%`
inside an AppContainer composed with a Job Object:

| Control | Default |
|---|---|
| AppContainer | Profile `VeaselApprovedShell` via `PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES` |
| Workspace ACL | AppContainer SID granted read/write/execute/delete on the workspace directory only |
| Process tree | Assigned to a Job Object before resume (`CREATE_SUSPENDED` → assign → resume) |
| Lifetime | `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` (descendants die when the job handle closes) |
| Active processes | Cap of 64 |
| Job memory | Cap of 512 MiB |
| Breakaway | Not permitted |
| Network | Denied by default (no network capability SIDs); `VEASEL_SHELL_SANDBOX_NETWORK=allow` adds `internetClient` / related well-known SIDs |
| Environment | Inherited from the Veasel process (may carry credentials) |
| Capability flag | `shell.sandbox.windows` |

This is AppContainer + Job Object containment, not a VM and not Codex-level WFP
helper-service isolation. System paths that already allow ALL APPLICATION
PACKAGES may remain readable/executable. See
[`compatibility/shell-windows-job-sandbox.md`](compatibility/shell-windows-job-sandbox.md).

## Autonomous benchmark path

The separately opt-in autonomous benchmark path is fail-closed OS-sandboxed on
the platform backend when present: Linux Bubblewrap (`bwrap`), macOS Seatbelt
(`/usr/bin/sandbox-exec`), and Windows AppContainer + Job Object. Platforms
without that backend refuse to start a process. Autonomous commands always
deny network sharing; Linux and macOS also filter the environment to an
allowlist (Windows AppContainer still inherits process env — a documented
backend limit). Do not treat this as a VM or a boundary against a hostile
kernel. MCP stdio does not use `VEASEL_SHELL_SANDBOX`; it has a separate
opt-in under `VEASEL_MCP_STDIO_SANDBOX` (Linux Bubblewrap / macOS Seatbelt /
Windows AppContainer when available; default off).

## Limits and API trust

Commands are limited to 8 KiB of single-line UTF-8 text, a workspace-relative
existing working directory, a timeout from 1 to 300 seconds, two concurrent
executions per server, and at most 64 KiB of combined stdout and stderr. Control
Unicode line separators, and bidirectional formatting characters are rejected
so the TUI review cannot hide command text. These bounds limit resource use; they do not make an
untrusted command safe.

Shell command list/inspect/approve responses include a computed `sandbox`
object (`mode`, `will_wrap`, `backend`) from `VEASEL_SHELL_SANDBOX` and the
current platform backends so reviewers see wrap intent before approval. MCP
tool-call reviews expose the parallel `stdio_sandbox` object from
`VEASEL_MCP_STDIO_SANDBOX` (default off).

The API is loopback-only and has no authentication token. A local same-user
process can access session APIs and invoke approvals. Treat same-user processes
as trusted, keep the server local, and do not expose its API to a network.

Workspace cwd validation only checks the initial working directory; a command
can still attempt to leave it. Do not approve a command whose filesystem,
network, or credential effects you have not reviewed.
