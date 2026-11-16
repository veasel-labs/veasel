# Veasel Desktop — provenance (COPY-ONLY transfer)

This directory is an **unmodified copy** of the Agent Toolkit Desktop
application, transferred under the copy-first rule of epic
[veasel-labs/veasel#689](https://github.com/veasel-labs/veasel/issues/689)
and ADR-0001 decision 10 (Electron Desktop host, owner decision
2026-11-16).

## Source

- Repository: `ulises-jeremias/agent-toolkit` (MIT License,
  Copyright (c) 2026 Ulises Jeremias)
- Source commit: `cfebbb7adcae19e91f30033976394c703325b762`
  (`chore(release): prepare v1.47.5`)
- Source path: `apps/desktop/`
- Transfer method: `git archive <commit> apps/desktop`, extracted
  verbatim — no file was edited, renamed or regenerated.
- Verification: recursive diff against a fresh archive extraction
  reported zero differences; per-file SHA-256 checksums are in
  `SHA256SUMS.txt` (493 copied files plus this provenance note).

## Attribution

Original work by the Agent Toolkit maintainers, MIT License (see the
repository `LICENSE`). Veasel branding, backend attachment (the Veasel
V backend is the only runtime), and any adaptation land in separate,
later commits — never as silent edits inside this copy.

## Scope note

`resources/`, `public/world/` art and the shell's non-Focus features
were copied as-is to preserve working code and tests. Features that
have no Veasel backend contract yet stay inert until explicitly wired
or removed by a reviewed follow-up; the Focus feature is the first
adaptation target (issue #692).

## Focus feature addition (2026-11-16, stacked on the COPY-ONLY transfer)

The Focus feature set (`src/features/focus/`, `src/data/focus.tsx`,
`src/data/focus.test.ts`, `src/types/focus.d.ts`) does not exist in
Agent Toolkit Desktop `main` (`cfebbb7a`); it was copied verbatim the
same way from the Focus branch:

- Repository: `ulises-jeremias/agent-toolkit` (MIT)
- Source commit: `ac2cd125` (`fix(desktop): scope Codex experimental API to Plan`)
- Source paths: `apps/desktop/src/features/focus/`, `apps/desktop/src/data/focus.tsx`,
  `apps/desktop/src/data/focus.test.ts`, `apps/desktop/src/types/focus.d.ts`
- Verification: recursive diff against a fresh `git archive ac2cd125`
  extraction reported zero differences at copy time.

This matches the earlier step-1 Focus copy already in `gui/focus/`
(veasel PR #702), which came from the same source commit.
