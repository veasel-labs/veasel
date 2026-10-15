# Windows shell Job Object sandbox — study pin

**Codex CLI upstream:** [openai/codex](https://github.com/openai/codex)
**Pinned commit:** [`dd178bb7cabb828b253992e082301fa7bf18c735`](https://github.com/openai/codex/tree/dd178bb7cabb828b253992e082301fa7bf18c735)
**Primary sources:** [`codex-rs/windows-sandbox-rs/`](https://github.com/openai/codex/tree/dd178bb7cabb828b253992e082301fa7bf18c735/codex-rs/windows-sandbox-rs), [`codex-rs/utils/pty/src/win/job.rs`](https://github.com/openai/codex/blob/dd178bb7cabb828b253992e082301fa7bf18c735/codex-rs/utils/pty/src/win/job.rs)
**License:** Apache-2.0

**Study date:** 2026-10-15

## What was studied

Codex keeps user approval separate from OS sandbox enforcement. Its Windows
path is a large restricted-token / ACL / WFP / helper-service stack
(`windows-sandbox-rs`) plus Job Objects for process-tree lifetime
(`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`). Full Codex parity includes private
logon identities, capability SIDs, workspace ACL rewriting, and network
filtering—far beyond a honest first Veasel slice. Restricted-token + fresh
interactive logon combinations have also shown OS-level logon-session leak
risks in the field; Veasel therefore avoids that logon pattern.

## What Veasel adapted (principles only)

- Authorization (durable inspect/approve) stays mandatory; the Job Object wrap
  is defense-in-depth for **manually approved** Windows shell.
- Create a Job Object with `KILL_ON_JOB_CLOSE`, an active-process cap (64), and
  a job memory cap (512 MiB); do not enable breakaway.
- Spawn with `CREATE_SUSPENDED`, `AssignProcessToJobObject`, then
  `ResumeThread` so the child is born into the job without a race.
- Best-effort `CreateRestrictedToken(... DISABLE_MAX_PRIVILEGE ...)` +
  `CreateProcessAsUser` when the OS allows; otherwise Job Object + ordinary
  `CreateProcess` still wraps the tree.
- Shared knobs `VEASEL_SHELL_SANDBOX=auto|off|require` and
  `VEASEL_SHELL_SANDBOX_NETWORK` (network allow is accepted for API symmetry
  but **ignored**—Job Objects do not isolate network).
- Capability `shell.sandbox.windows` is true only when the Job Object wrap will
  run.

No Codex source was copied. Veasel does **not** claim AppContainer, WFP, or
Codex-level Windows sandbox guarantees.

## Residual risks (must stay visible)

| Risk | Status |
|---|---|
| Filesystem writes outside the workspace | Still allowed under the OS user ACL |
| Network egress/ingress | Not isolated; `VEASEL_SHELL_SANDBOX_NETWORK` has no effect yet |
| Inherited environment credentials | Still present on the approved path |
| Privilege strip | Best-effort only; may fall back to Job Object without restricted token |
| AppContainer / LPAC | Not implemented |
