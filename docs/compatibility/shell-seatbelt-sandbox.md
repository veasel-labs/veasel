# macOS shell Seatbelt sandbox — study pin

**Codex CLI upstream:** [openai/codex](https://github.com/openai/codex)
**Pinned commit:** [`160b2b1ef62114eeb41e41e5e3be0000d944b713`](https://github.com/openai/codex/tree/160b2b1ef62114eeb41e41e5e3be0000d944b713)
**Primary sources:** [`codex-rs/sandboxing/src/seatbelt.rs`](https://github.com/openai/codex/blob/160b2b1ef62114eeb41e41e5e3be0000d944b713/codex-rs/sandboxing/src/seatbelt.rs), [`seatbelt_base_policy.sbpl`](https://github.com/openai/codex/blob/160b2b1ef62114eeb41e41e5e3be0000d944b713/codex-rs/sandboxing/src/seatbelt_base_policy.sbpl)
**License:** Apache-2.0

**Study date:** 2026-10-15

## What was studied

Codex keeps user approval separate from OS sandbox enforcement and invokes
`/usr/bin/sandbox-exec` only (never a PATH lookup). Seatbelt profiles start
deny-default, allow process lifecycle primitives, grant read access as policy
requires, and carve writable roots with `(subpath (param …))` definitions.
Network is denied unless explicitly allowed. Codex's Windows path uses
restricted-token / elevated backends that are substantially more complex than
Veasel can ship honestly in this slice.

## What Veasel adapted (principles only)

- Authorization (durable inspect/approve) stays mandatory; Seatbelt is
  defense-in-depth for **manually approved** macOS shell.
- Invoke only `/usr/bin/sandbox-exec`.
- Default approved policy: host readable, writes limited to the workspace and
  temp directories, deny reads/writes under `/Users`, `/var/root`, and
  `/Volumes` except the workspace carve-out, network denied unless
  `VEASEL_SHELL_SANDBOX_NETWORK=allow`.
- Shared knobs `VEASEL_SHELL_SANDBOX` (default `require`; `auto` explicitly
  permits fallback, `off` disables wrapping) and `VEASEL_SHELL_SANDBOX_NETWORK`;
  capability `shell.sandbox.seatbelt` is true only when wrap will run.
- Autonomous macOS shell also uses Seatbelt fail-closed with a filtered
  environment and network denied (never shares the approved-path network knob).
- Windows AppContainer + Job Object wrap is documented separately in
  [`shell-windows-job-sandbox.md`](shell-windows-job-sandbox.md).

## MCP stdio reuse (same pin)

Trusted MCP stdio may opt into the same `/usr/bin/sandbox-exec` binary via
`VEASEL_MCP_STDIO_SANDBOX` defaults to `require` (unset/invalid fails closed);
explicit `auto` allows unsandboxed fallback and `off` disables wrapping. The
MCP profile keeps network shared (many servers need outbound HTTPS), carves
writable `PLUGIN_ROOT` and `PLUGIN_DATA` instead of a workspace root, and
advertises `mcp.stdio.sandbox.seatbelt` only when wrap will run. Windows MCP
stdio AppContainer wrap is documented in
[`shell-windows-job-sandbox.md`](shell-windows-job-sandbox.md).

No Codex Seatbelt source or SBPL files were copied. Veasel does not claim
Codex-level sandbox guarantees. `sandbox-exec` remains best-effort and may be
deprecated or constrained by future macOS releases.
