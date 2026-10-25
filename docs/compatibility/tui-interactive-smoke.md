# TUI interactive smoke — platform matrix

**Harness:** [`scripts/standalone-tui-smoke.py`](../../scripts/standalone-tui-smoke.py)
**Local keyboard exercise:** [`tui/scripts/exercise-keyboard.py`](../../tui/scripts/exercise-keyboard.py)
**Study date:** 2026-10-23

## Scope

This track packages the standalone TUI for Linux, macOS, and Windows in CI.
Interactive PTY smoke is a separate gate from packaging: it proves the bundled
`veasel-tui` binary can open against a local backend, reach a seeded session,
navigate provider settings, send a prompt through the backend, render a
mock-provider reply, persist both turns, and exit cleanly.

## Automated coverage

| Platform | Runner | Standalone terminal smoke | Notes |
|----------|--------|----------------------|-------|
| Linux x64 | `ubuntu-22.04` (V backend job) | Yes | Existing CI step |
| macOS arm64 | `macos-latest` (V backend job) | Yes | Same Unix `pty` harness as Linux |
| Windows x64 | `windows-latest` (V backend job) | Yes | Native ConPTY driver in `scripts/windows_conpty.py` |

The same journey runs through Unix PTY on Linux/macOS and native ConPTY on
Windows. All three packaged-client smoke paths passed in [CI run
40140177406](https://github.com/veasel-labs/veasel/actions/runs/40140177406)
for commit `6ab4b3915522425cced46c0263c647068c3f097c`. This verifies the smoke
journey on the pinned CI runners. Measured startup/render baselines and broader
interactive journeys remain separate work.

## Windows acceptance covered by CI

The Windows CI job builds `dist/veasel.exe` and `dist/veasel-tui.exe`, starts
the backend and mock provider in isolated temporary state, and drives the
packaged client in a 100×24 pseudoconsole. The shared smoke checks:

1. Start the backend on loopback and confirm `GET /v1/health`.
2. Launch `veasel-tui.exe` in Windows Terminal (or ConPTY-capable host).
3. Confirm home chrome: connected status, `SESSIONS`, `VEASEL` brand.
4. Press `s` and confirm `MODEL SETTINGS` opens; Tab cycles provider scopes.
5. Search for `anthorpic` and confirm typo-tolerant discovery finds Anthropic.
6. Open the seeded session and send `Stream incrementally`. Confirm the TUI renders the first reply chunk before the mock provider releases the second, then renders the complete reply.
7. Confirm both turns are persisted by the backend; the command palette's Quit command exits cleanly.
The mock provider uses a fixture key and makes no external model requests.
The Python driver uses `CreatePseudoConsole`, Win32 pipes, and
`PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`; WSL/Git Bash are not used as a proxy for
ConPTY. Record CI failures with the visible terminal tail emitted by the smoke.

## Measured Linux TUI baselines (this host only)

Harness: [`benchmarks/tui-startup.mjs`](../../benchmarks/tui-startup.mjs)  
Report: [`benchmarks/reports/tui-startup-linux-x64-2026-10-23.json`](../../benchmarks/reports/tui-startup-linux-x64-2026-10-23.json)
Binary comparison: published and locally optimized Veasel Code Terminal `0.64.6-next.0` on Linux x64 (`7.2.9-arch1-1`, 24 CPUs), both built with Bun 1.4.2

| Probe | Samples | Published p50 | Optimized p50 | Notes |
|-------|--------:|--------------:|--------------:|-------|
| `veasel-tui --version` wall | 15 | 55.2 ms | 35.3 ms | RSS: 54,568 → 34,308 KiB |
| `veasel-tui --help` wall | 15 | 55.4 ms | 34.6 ms | RSS: 54,612 → 34,360 KiB |
| PTY time to connected home | 15 | 92.7 ms | 92.6 ms | Isolated release backend; markers `connected` + `SESSIONS` + `VEASEL` |

The 2026-10-23 comparison used the same host, Bun 1.4.2, backend release, and
harness. The short CLI paths improved by about 36–38% in wall time and 37% in
RSS. PTY connected-home readiness was effectively unchanged, so this
optimization does not claim faster interactive startup or frame rate. The
historical v0.41.0-next.0 baseline from 2026-10-15 measured 41.1 ms for
`--version`, 41.9 ms for `--help`, and 70.0 ms to connected home; it remains a
separate release-to-release trend point, not the controlled comparison above.

Method exclusions (do **not** claim otherwise): not interactive render FPS, not
model/token latency, not coding-task quality, not macOS/Windows numbers.

Repeat with the same harness before publishing broader performance claims.
macOS/Windows interactive baselines remain unmeasured here.

## Remaining product gaps

- macOS/Windows measured TUI baselines (Linux only above).
- Broader interactive coverage beyond the short standalone smoke path
  (approvals, streaming, MCP OAuth browser open, long diffs).
- See also [`../IMPLEMENTATION_PLAN.md`](../IMPLEMENTATION_PLAN.md) and
  [`../COMPETITIVE_SOURCE_STUDY.md`](../COMPETITIVE_SOURCE_STUDY.md).
