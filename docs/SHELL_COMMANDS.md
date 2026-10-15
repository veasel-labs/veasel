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
authorization gate; Bubblewrap is defense-in-depth containment, not a bypass of
review.

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
| Capability flag | `shell.sandbox.bubblewrap` is advertised only when this wrap will run |

Configuration:

- `VEASEL_SHELL_SANDBOX=auto` (default): use Bubblewrap when available; otherwise
  fall back to unsandboxed execution and do **not** advertise the capability.
- `VEASEL_SHELL_SANDBOX=off`: never wrap approved commands.
- `VEASEL_SHELL_SANDBOX=require`: fail closed if `bwrap` is missing (no
  unsandboxed fallback).

This is best-effort containment, not a VM. Host-readable files outside the
masked paths can still be read; pre-existing hard links inside the workspace can
refer to host inodes; inherited environment variables may still carry
credentials. macOS and Windows approved shell remain unsandboxed.

Workspace cwd validation only checks the initial working directory; a command
can still attempt to leave it. Do not approve a command whose filesystem,
network, or credential effects you have not reviewed.

## Autonomous benchmark path

The separately opt-in autonomous benchmark path is supported only on Linux. It
requires Bubblewrap (`bwrap`) and fails closed if the executable or namespace
setup is unavailable. Its command uses the same mount layout, always filters the
environment to an allowlist, and never enables network sharing. Do not treat
this as a VM or a boundary against a hostile kernel. MCP stdio processes do not
use this sandbox.

## Limits and API trust

Commands are limited to 8 KiB of single-line UTF-8 text, a workspace-relative
existing working directory, a timeout from 1 to 300 seconds, two concurrent
executions per server, and at most 64 KiB of combined stdout and stderr. Control
Unicode line separators, and bidirectional formatting characters are rejected
so the TUI review cannot hide command text. These bounds limit resource use; they do not make an
untrusted command safe.

The API is loopback-only and has no authentication token. A local same-user
process can access session APIs and invoke approvals. Treat same-user processes
as trusted, keep the server local, and do not expose its API to a network.
