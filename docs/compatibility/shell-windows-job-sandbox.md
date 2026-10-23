# Windows shell AppContainer + Job Object sandbox — study pin

**Codex CLI upstream:** [openai/codex](https://github.com/openai/codex)
**Pinned commit:** [`dd178bb7cabb828b253992e082301fa7bf18c735`](https://github.com/openai/codex/tree/dd178bb7cabb828b253992e082301fa7bf18c735)
**Primary sources:** [`codex-rs/windows-sandbox-rs/`](https://github.com/openai/codex/tree/dd178bb7cabb828b253992e082301fa7bf18c735/codex-rs/windows-sandbox-rs), [`codex-rs/utils/pty/src/win/job.rs`](https://github.com/openai/codex/blob/dd178bb7cabb828b253992e082301fa7bf18c735/codex-rs/utils/pty/src/win/job.rs)
**License:** Apache-2.0

**Study date:** 2026-10-15 (AppContainer deepening)

## What was studied

Codex keeps user approval separate from OS sandbox enforcement. Its Windows
path is a large restricted-token / ACL / WFP / helper-service stack
(`windows-sandbox-rs`) plus Job Objects for process-tree lifetime
(`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`). Full Codex parity includes private
logon identities, capability SIDs, workspace ACL rewriting, and network
filtering—far beyond Veasel's current slice. Restricted-token + fresh
interactive logon combinations have also shown OS-level logon-session leak
risks in the field; Veasel therefore avoids that logon pattern.

## What Veasel adapted (principles only)

- Authorization (durable inspect/approve) stays mandatory; the
  AppContainer + Job Object wrap is defense-in-depth for **manually approved**
  Windows shell.
- Create/reuse an AppContainer profile (`VeaselApprovedShell`) and launch via
  `PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES`.
- Grant the AppContainer SID explicit ACL access on the workspace directory
  only (sibling paths remain denied under the AppContainer token).
- Network: no `internetClient` / `privateNetworkClientServer` capability SIDs
  by default (deny). `VEASEL_SHELL_SANDBOX_NETWORK=allow` adds those SIDs.
- Compose with a Job Object: `KILL_ON_JOB_CLOSE`, active-process cap (64), job
  memory cap (512 MiB); spawn `CREATE_SUSPENDED`, `AssignProcessToJobObject`,
  then `ResumeThread`.
- Shared knobs `VEASEL_SHELL_SANDBOX` (default `require`; explicit `auto` permits
  fallback and `off` disables wrapping) and `VEASEL_SHELL_SANDBOX_NETWORK`.
- Capability `shell.sandbox.windows` is true only when the AppContainer + Job
  Object wrap will run.
- Autonomous Windows shell also uses AppContainer + Job fail-closed with
  network denied and receives only the platform environment allowlist
  (`PATH`, `PATHEXT`, `SYSTEMROOT`, `WINDIR`, `COMSPEC`, `TEMP`, `TMP`,
  `USERPROFILE`). Environment variable names are matched case-insensitively,
  then normalized in the child block.

No Codex source was copied. Veasel does **not** claim Codex-level WFP
helper-service filters, private logon identities, or LPAC.

## Trusted MCP stdio (same C helper, separate profile)

Fail-closed by default via `VEASEL_MCP_STDIO_SANDBOX=require` (explicit `auto`
permits fallback; `off` disables wrapping). When wrapping:

- Uses AppContainer profile `VeaselTrustedMcp` (not the approved-shell profile).
- Grants ACL on `PLUGIN_ROOT` and `PLUGIN_DATA` (and cwd when distinct).
- Always adds network capability SIDs (parity with Linux Bubblewrap / macOS
  Seatbelt MCP wraps; many servers need outbound HTTPS).
- Advertises `mcp.stdio.sandbox.windows` only when the wrap will run.
- Long-lived stdio pipes are returned to the V MCP transport (not a fire-and-
  forget shell capture).

## Residual risks (must stay visible)

| Risk | Status |
|---|---|
| Filesystem outside workspace | Denied for paths without an AppContainer ACL grant; system paths that already allow ALL APPLICATION PACKAGES may still be readable/executable |
| Network egress/ingress | Denied by default via missing capability SIDs; allow adds well-known network capability SIDs (not a custom WFP policy) |
| Inherited environment credentials | Filtered from approved shell children; only the platform environment allowlist is passed |
| LPAC / All Application Packages opt-out | Not implemented (would break `%COMSPEC%` without broader grants) |
| Codex WFP helper-service | Not implemented |
