# Veasel GUI — COPY-ONLY Focus transfer, do not edit yet

For epic [#689](https://github.com/veasel-labs/veasel/issues/689) /
issue [#692](https://github.com/veasel-labs/veasel/issues/692), per the
copy-first rule in `docs/consolidation/ROADMAP_AND_COPY_MAP.md`.

- Source repo: `ulises-jeremias/agent-toolkit` (MIT)
- Source commit: `ec993aa514bf47a28abf728a6621dbe349df72b1` (main)
- Source paths: `apps/desktop/src/features/focus/` (12 files),
  `apps/desktop/src/types/focus.d.ts`
- Target: `gui/focus/`, `gui/types/` in `veasel-labs/veasel`
- Integrity: `gui/SHA256SUMS.txt`, verified identical (`diff -r`) at copy time.

This is step 1 of #692 only: unmodified transfer. It is **not built, not
wired, and not shipped**. Step 2 (separate PR) rewires these components
to the canonical Veasel session/event API so TUI and GUI share one
persistent session model — no duplicate engine (ADR-0001 decision 1).
Electron main/PTY host code is intentionally not copied; the session
runtime lives in the Veasel server.
