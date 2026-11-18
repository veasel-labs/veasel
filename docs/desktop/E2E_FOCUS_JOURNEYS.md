# Focus journeys (click-driven Electron acceptance)

Epic veasel-labs/veasel#689. Spec: `desktop/e2e/electron/focus-journeys.spec.ts`; oracle proofs without a display:
`desktop/e2e/electron/focus-fixture.api.spec.ts`. Latest run: [`E2E_EVIDENCE.md`](E2E_EVIDENCE.md).

## What it is

Real clicks and keyboard (Playwright `_electron`) against the built Desktop app and the real V backend
(`veasel serve`). The agent is a deterministic fake installed CLI (`desktop/e2e/electron/fake-cli/fake-claude.mjs`,
the `claude` stream-json protocol the backend already speaks, including tool_use/tool_result frames so durable
turn outcomes are real; `fake-codex.mjs` is a decoy that must never be spawned). No credentials or spend; the
global model config is EMPTY (#751). Verdicts come from independent oracles, never the UI's own claims: disposable
repo hash / `git status` / `git diff`, the repo's test command run by the test, the fake CLI's JSONL log, process
liveness, backend HTTP API reads (including `outcome`, stored preferences, 409s).

Known product bugs are encoded as `test.fail(true, reason)`: the oracle is not weakened; the test passes only while
the bug exists and starts failing (so the marker must go) once it is fixed. The evidence table labels them
"FAIL (known product bug)".

## Run locally (isolated container, no host display)

```bash
v -o "$SCRATCH/bin/veasel" .
cd desktop && pnpm install --frozen-lockfile && node node_modules/electron/install.js && pnpm build:all
docker build -t veasel-e2e-focus:local e2e/docker
VEASEL_BIN="$SCRATCH/bin/veasel" OUT_DIR="$SCRATCH/out" e2e/docker/run-focus-journeys.sh focus-journeys   # or no arg: also the fixture spec
node scripts/e2e-evidence.mjs "$SCRATCH/out/evidence/evidence.jsonl" "$SCRATCH/out/results.json" "$SCRATCH/bin/veasel" ../docs/desktop/E2E_EVIDENCE.md
```

The container: `--memory=3g --memory-swap=3g --cpus=2 --pids-limit=1024 --cap-drop=ALL --security-opt
no-new-privileges --network=none --read-only`, host uid/gid, repo mounted read-only, tmpfs for HOME/XDG/data
dirs, results bind-mounted to `OUT_DIR`, Xvfb inside. Electron runs with `--no-sandbox` ONLY here (`VEASEL_E2E_NO_SANDBOX=1`
baked into the image): `--cap-drop=ALL` removes the capabilities Chromium's sandbox needs. The base image is pinned by digest
(Arch, because the backend under test needs the host's glibc 2.43); `journey-env.ts` refuses to run without
`VEASEL_E2E_XVFB=1` and `DISPLAY`. Observed peak: about 0.6 GiB RSS of the 3 GiB cap, about 170 pids.

## CI

`.github/workflows/desktop-e2e.yml` (separate, non-required workflow): builds the backend and Desktop on
ubuntu-24.04 and runs the same spec under `xvfb-run`, uploads evidence and a step summary. It does not gate releases.

## Fixture-only workarounds (each backed by a known bug above)

- The start form cannot list or link a project (J2), so sessions are created through the API with stored
  preferences and then opened by clicking them in the Sessions list; everything after (composer, approvals, keyboard,
  reopen) is click/keyboard driven.
- The thread list and pending approvals load at open time, so tests reload/reselect the session to load server state
  (J3b, J4c). One fresh session per approval journey.
- J9 drives the TUI through its own API client (`tui/src/api-client.ts`, `backend-auth.ts`) under `bun`, not a pty; the
  OpenTUI screen is not click/visual driven. axe-core is only a transitive dependency, so its scan runs only if it resolves.
- The shared `fixtures.ts` still demands a backend binary for the legacy `workspace init`; the journeys pass the V
  binary and skip init.

## Product bugs found (repro: run the suite; each has a `test.fail` journey)

1. J2/J4b: Focus takes workspace and projects from the legacy ATK backend that #728 disabled (`backend.harness.path`
   is null; `useProjects`, `useLinkProject`, `ProjectChangesPanel`). The start form shows "No project linked yet",
   linking says "workspace is still starting" forever, and the Changes panel stays on "Reading working tree...". No
   session can be started from the UI on a clean install. Fix: source projects and git status from the V backend.
2. J3b (fixed here, see commit "render the approval dialog"): `readThreadSnapshot` never emitted `turn.started`, so
   `pendingApproval()` ignored the turn and the dialog never rendered; the pending approval was also numbered into the
   previous turn. Still open: a mid-turn approval is not pushed live (no SSE event/poll), so the dialog appears only
   after reopening the session.
3. J3c: the server emits `assistant.delta` while the CLI streams, but the Focus conversation text does not change.
4. J4c: the thread stays "Needs your answer" (composer disabled) after the approval is decided and the turn ends; live
   `turn.finished` events are always numbered turn 1.
5. J6/J8b (UI half; backend half fixed in #757): a running CLI turn shows no Stop button
   and the CLI process alive (`run_claude_cli_turn` never watches the cancel context). Fix: poll the operation cancel
   context in the read loop and `signal_term` the process.
6. J10: after `kill -9` of the backend Desktop shows no alert or message.
