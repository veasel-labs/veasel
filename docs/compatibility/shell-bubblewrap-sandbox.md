# Linux shell Bubblewrap sandbox — study pin

**Codex CLI upstream:** [openai/codex](https://github.com/openai/codex)
**Pinned commit:** [`a9b0815167c27ab13719dd12d13b63e02b70d221`](https://github.com/openai/codex/tree/a9b0815167c27ab13719dd12d13b63e02b70d221)
**Primary sources:** [`codex-rs/core/src/tools/sandboxing.rs`](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/core/src/tools/sandboxing.rs)
**License:** Apache-2.0

**mini-SWE-agent upstream:** [SWE-agent/mini-SWE-agent](https://github.com/SWE-agent/mini-SWE-agent)
**Pinned commit:** [`04d809ceab9df28f9adaed044884180159172930`](https://github.com/SWE-agent/mini-SWE-agent/tree/04d809ceab9df28f9adaed044884180159172930)
**Primary source:** [`src/minisweagent/environments/extra/bubblewrap.py`](https://github.com/SWE-agent/mini-SWE-agent/blob/04d809ceab9df28f9adaed044884180159172930/src/minisweagent/environments/extra/bubblewrap.py)
**License:** MIT

**Study date:** 2026-10-15

## What was studied

Codex keeps user approval separate from OS sandbox enforcement and implements
platform-specific sandbox modules. mini-SWE-agent's optional Bubblewrap
environment bind-mounts selected host paths and the working directory and does
not unshare the network by default.

## What Veasel adapted (principles only)

Veasel already used fail-closed Bubblewrap for autonomous Linux shell. This
change extends a related policy to **manually approved** shell commands when
`bwrap` is available:

- Authorization (durable inspect/approve) stays mandatory; sandbox is
  defense-in-depth.
- Default approved policy: read-only host, writable workspace, masked
  home/runtime mounts, `--unshare-all`, network denied unless
  `VEASEL_SHELL_SANDBOX_NETWORK=allow`.
- `VEASEL_SHELL_SANDBOX=auto|off|require` controls wrap vs honest unsandboxed
  fallback; capability `shell.sandbox.bubblewrap` is true only when wrap will
  run.
- Autonomous path remains stricter (filtered environment, always fail-closed,
  never share network).

No Codex or mini-SWE-agent source was copied. Veasel does not claim Codex-level
sandbox guarantees. macOS Seatbelt parity is documented in
[`shell-seatbelt-sandbox.md`](shell-seatbelt-sandbox.md) and
[`shell-windows-job-sandbox.md`](shell-windows-job-sandbox.md).
