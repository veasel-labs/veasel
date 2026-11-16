# Focus reference copy — COPY-ONLY, do not edit

Verbatim copy for epic [#689](https://github.com/veasel-labs/veasel/issues/689) /
issue [#691](https://github.com/veasel-labs/veasel/issues/691), per the
copy-first rule in `docs/consolidation/ROADMAP_AND_COPY_MAP.md`.

- Source repo: `ulises-jeremias/agent-toolkit` (MIT, see source `LICENSE`)
- Source commit: `ac2cd125` (`feat/focus-opencode-acp`, NOT on toolkit main)
- Source paths: `apps/desktop/electron/focus/{adapter,claude,codex,opencode,service,providers,journal}.ts`,
  `apps/desktop/electron/focus/testing/fake-{claude,codex,opencode}.mjs`
- Target: `tests/focus_reference/` in `veasel-labs/veasel`
- Integrity: `SHA256SUMS.txt` verified identical to source at copy time.

These files are the protocol reference (Claude Code stream-json, Codex
app-server JSON-RPC, OpenCode ACP) and scripted-provider fixtures for the
future V adapters (`provider_cli_*.v`). They are not built or shipped.
Adaptation happens in a separate commit/PR; edits here require updating
this README and the checksums.
