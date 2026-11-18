# Focus journeys (click-driven Electron acceptance)

Epic veasel-labs/veasel#689. Spec: `desktop/e2e/electron/focus-journeys.spec.ts`.
Evidence of the latest run: [`E2E_EVIDENCE.md`](E2E_EVIDENCE.md).

## What it is

Real clicks and keyboard (Playwright `_electron`) against the built Desktop app and the
real V backend (`veasel serve`). The "agent" is a deterministic fake installed CLI
(`desktop/e2e/electron/fake-cli/fake-claude.mjs`, the `claude` stream-json protocol the backend
already speaks; `fake-codex.mjs` is a decoy that must never be spawned). No provider
credentials or spend. Verdicts come from independent oracles, never from the UI's own claims:
disposable repo hash / `git status` / `git diff`, the repo's test command run by the test,
the fake CLI's JSONL spawn log, process liveness, and the backend's HTTP API.

| Journey | Oracle |
|---------|--------|
| J1 provider discovery | `GET /v1/providers/cli` from the backend, no CLI turn spawned |
| J2 open workspace | workspace symlink realpath equals the disposable repo |
| J3 provider choice (no model) | fake CLI spawn log equals `[claude]`; operation provider `claude-code` (regression for #735) |
| J4 approve edit | file sha256 changed, `node test.js` red then green, `git diff` has the fix |
| J5 reject edit | README sha256, `git status` and `git diff` identical; CLI logged `edit-denied` |
| J6 cancel | fake CLI pid no longer alive; repo unchanged |
| J7 reopen | backend transcript for the same session id after restart |
| J8 keyboard | file changed after Enter on "Allow once"; shell never allowed; pid dead after Escape |
| J9 TUI continuity | TUI's own API client resumes the exact id; its message is in the backend transcript and visible in Desktop |
| J10 backend crash | SIGKILL backend; no new CLI result frame; repo unchanged; badge leaves Connected |
| J11 approval expiry | `test.fixme`: wait is a fixed 10 min (`max_agent_turn_duration`, api.v), no knob |

J9 limits: the TUI is driven through its own API client (`tui/src/api-client.ts` +
`backend-auth.ts`) run by `bun`, not through a pty. The interactive OpenTUI screen is not
click/visual driven. The folder picker in J2 is stubbed at the Electron `dialog` boundary
(same approach as `project-link.spec.ts`). axe-core is only a transitive dependency, so the
a11y scan in J8 runs only if it resolves.

## Run

Needs `xvfb-run` (`xorg-server-xvfb` on Arch, `xvfb` on Debian/Ubuntu). The spec refuses to
start without `VEASEL_E2E_XVFB=1` and `DISPLAY`, so it can never open a window on a live
session. All environment (HOME, XDG_*, `VEASEL_DATA_DIR`, `VEASEL_SECRET_STORE=file`) is a
throwaway directory under `TMPDIR`.

```bash
# 1. backend (V) and app builds
v -o "$SCRATCH/bin/veasel" .
cd desktop && pnpm install --frozen-lockfile && pnpm build:all

# 2. fixture oracles, no display, no Electron
VEASEL_BACKEND_BIN="$SCRATCH/bin/veasel" pnpm exec playwright test -c playwright.fixture.config.ts

# 3. journeys under Xvfb (ATK_E2E_BACKEND_BIN is the agent-toolkit binary the shared fixture uses for `workspace init`)
VEASEL_E2E_XVFB=1 VEASEL_BACKEND_BIN="$SCRATCH/bin/veasel" ATK_E2E_BACKEND_BIN=/usr/bin/agent-toolkit \
  VEASEL_E2E_EVIDENCE_DIR="$SCRATCH/evidence" PLAYWRIGHT_JSON_OUTPUT_NAME="$SCRATCH/results.json" \
  xvfb-run -a pnpm exec playwright test --project=electron focus-journeys --reporter=list,json

# 4. evidence table from that run
node scripts/e2e-evidence.mjs "$SCRATCH/evidence/evidence.jsonl" "$SCRATCH/results.json" "$SCRATCH/bin/veasel" ../docs/desktop/E2E_EVIDENCE.md
```

On a shared workstation wrap every heavy command (build, install, tsc, playwright) in your
resource-capping launcher (the `bounded` wrapper used for this work). Traces and screenshots
land in `desktop/test-results/` (`focus-journeys-trace.zip`, attachments).

## Known product findings from building this suite

1. `complete_agent_with_model_override` (api.v) resolves the session's global default provider
   before applying a per-turn installed-CLI override. With no API key configured, every Focus
   turn fails with "model credentials are not configured for openai-compatible", even though
   the CLI provider needs none. The harness configures a placeholder default to get past it
   (`configurePlaceholderDefault`).
2. Focus `send` (`desktop/src/data/veasel-bridge.ts`) posts without `Prefer: respond-async`
   (the TUI sends it), so the request blocks until the turn ends. With an approval pending the
   turn cannot end, so the UI may sit on "Starting..." and never show the approval. Suspected
   from reading the code; J3/J4 exist to confirm or refute it.
