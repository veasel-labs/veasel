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
/S /C` on Windows. Standard input is non-interactive. These commands run as the
Veasel server's OS user, inherit its environment (including credentials), and
can access files and network services available to that user. Workspace cwd
validation only checks the initial working directory; a command can access
paths outside it. Do not approve a command whose filesystem, network, or
credential effects you have not reviewed.

The separately opt-in autonomous benchmark path is supported only on Linux. It
requires Bubblewrap (`bwrap`) and fails closed if the executable or namespace
setup is unavailable. Its command runs with the host filesystem read-only, the
chosen workspace writable, `/home`, `/root`, `/run`, `/mnt`, `/media`, and `/tmp`
masked where present, and networking isolated. The subprocess receives a
filtered environment. Do not treat this as a VM or a boundary against a hostile
kernel: other host-readable files outside the masked paths can still be read,
and hard links already in the workspace can refer to host inodes. Manually
approved commands and MCP stdio processes do not use this sandbox.

Commands are limited to 8 KiB of single-line UTF-8 text, a workspace-relative
existing working directory, a timeout from 1 to 300 seconds, two concurrent
executions per server, and at most 64 KiB of combined stdout and stderr. Control
Unicode line separators, and bidirectional formatting characters are rejected
so the TUI review cannot hide command text. These bounds limit resource use; they do not make an
untrusted command safe.

The API is loopback-only and has no authentication token. A local same-user
process can access session APIs and invoke approvals. Treat same-user processes
as trusted, keep the server local, and do not expose its API to a network.
