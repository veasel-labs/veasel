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

- Approval/stop journeys use a fresh API-created session with stored preferences (the start form itself is covered by J2).
- The thread list and pending approvals load at open time, so tests reload/reselect the session to load server state
  (J3b, J4c). One fresh session per approval journey.
- J9 drives the TUI through its own API client (`tui/src/api-client.ts`, `backend-auth.ts`) under `bun`, not a pty; the
  OpenTUI screen is not click/visual driven. axe-core is only a transitive dependency, so its scan runs only if it resolves.
- The shared `fixtures.ts` still demands a backend binary for the legacy `workspace init`; the journeys pass the V
  binary and skip init.

## Product bugs found (repro: run the suite; each has a `test.fail` journey)

1. (fixed) J2/J4b: Focus took workspace, projects and git status from the legacy ATK backend that #728 disabled. It now uses
   the session's own directory: folders come from existing sessions plus the native picker, and the Changes panel reads
   `GET /v1/sessions/:id/workspace/git/changes|diff` from the V backend. Starting from the form also needed a session
   title (the backend rejects an empty one) and adding the new thread to the store. The old tab markup that axe flagged
   (aria-required-children) went away with it, so J8c now passes.
2. (fixed) J3b: a mid-turn approval was only loaded when a session was opened. While a turn runs the bridge now watches the
   pending-approval set (server events `session.turn_started/queued` start it, `turn_completed` stops it) and asks the store
   to re-read the thread when the set changes, so the dialog appears, and is retired once decided, without reopening.
   This also fixed J4c (the stale "Needs your answer" status): the re-read replaces it.
3. J3c: the server emits `assistant.delta` while the CLI streams, but the Focus conversation text does not change.
4. J6/J8b (UI half; the backend half was fixed in #757): a running CLI turn shows no Stop button, so the user cannot cancel
   from the UI.
5. J10: after `kill -9` of the backend Desktop shows no alert or message.
