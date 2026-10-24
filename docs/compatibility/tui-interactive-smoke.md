# TUI interactive smoke — platform matrix

**Harness:** [`scripts/standalone-tui-smoke.py`](../../scripts/standalone-tui-smoke.py)
**Local keyboard exercise:** [`tui/scripts/exercise-keyboard.py`](../../tui/scripts/exercise-keyboard.py)
**Study date:** 2026-10-23

## Scope

This track packages the standalone TUI for Linux, macOS, and Windows in CI.
Interactive PTY smoke is a separate gate from packaging: it proves the bundled
`veasel-tui` binary can open against a local backend, reach the connected home
screen, and exercise a short settings path.

## Automated coverage

| Platform | Runner | Standalone PTY smoke | Notes |
|----------|--------|----------------------|-------|
| Linux x64 | `ubuntu-22.04` (V backend job) | Yes | Existing CI step |
| macOS arm64 | `macos-latest` (V backend job) | Yes | Same Unix `pty` harness as Linux |
| Windows x64 | `windows-latest` (V backend job) | Yes | Native ConPTY driver in `scripts/windows_conpty.py`; passed on exact head `8dbd00d1` |

The same journey runs through Unix PTY on Linux/macOS and native ConPTY on
Windows. Each CI run repeats the complete journey three times and retains a
JSON startup report as the `tui-startup-<platform>` artifact. The metric starts
when the packaged TUI process is launched and stops when the connected home
markers are emitted; the backend is already healthy. These short hosted-runner
samples are for platform coverage and trend tracking, not a performance gate
or a stable cross-machine comparison. All three packaged-client smoke paths
passed in [CI run
39912654775](https://github.com/veasel-labs/veasel/actions/runs/39912654775)
for commit `8dbd00d1bb74f08ebc227dac2b07d7026a1e24da`. This verifies the smoke
journey on the pinned CI runners. This work adds per-run launch-to-home
measurements; render FPS and broader interactive journeys remain separate work.

## Windows acceptance covered by CI

The Windows CI job builds `dist/veasel.exe` and `dist/veasel-tui.exe`, starts
the backend in isolated temporary state, and drives the packaged client in a
100×24 pseudoconsole. The shared smoke checks:

1. Start the backend on loopback and confirm `GET /v1/health`.
2. Launch `veasel-tui.exe` in Windows Terminal (or ConPTY-capable host).
3. Confirm home chrome: connected status, `SESSIONS`, `VEASEL` brand.
4. Press `s` and confirm `MODEL SETTINGS` opens; Tab cycles provider scopes.
5. Search for `anthorpic` and confirm typo-tolerant discovery finds Anthropic.
6. Esc returns to the home session list; `q` exits cleanly.
The Python driver uses `CreatePseudoConsole`, Win32 pipes, and
`PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`; WSL/Git Bash are not used as a proxy for
ConPTY. Record CI failures with the visible terminal tail emitted by the smoke.

## Historical Linux TUI baselines (this host only)

Harness: [`benchmarks/tui-startup.mjs`](../../benchmarks/tui-startup.mjs)  
Report: [`benchmarks/reports/tui-startup-linux-x64-2026-10-15.json`](../../benchmarks/reports/tui-startup-linux-x64-2026-10-15.json)  
Binary: Veasel Code Terminal `0.41.0-next.0` on Linux x64 (`7.2.9-arch1-1`, 24 CPUs)

| Probe | Samples | p50 | Notes |
|-------|--------:|----:|-------|
| `veasel-tui --version` wall | 15 | 41.1 ms | Also p50 RSS ≈ 50.4 MiB (`ru_maxrss`) |
| `veasel-tui --help` wall | 15 | 41.9 ms | p50 RSS ≈ 50.3 MiB |
| PTY time to connected home | 5 | 70.0 ms | Isolated `veasel serve`; markers `connected` + `SESSIONS` + `VEASEL` |

Method exclusions (do **not** claim otherwise): not interactive render FPS, not
model/token latency, not coding-task quality, not macOS/Windows numbers.

Repeat with the same harness before publishing broader performance claims.
macOS/Windows interactive baselines remain unmeasured here.

## Linux CI-built binary sample

Report: [`benchmarks/reports/tui-startup-linux-ci-2026-10-24.json`](../../benchmarks/reports/tui-startup-linux-ci-2026-10-24.json). Three complete PTY journeys with the exact CI-built Linux binaries reached the connected home in 99.8 ms median (99.6–104.7 ms) on the local Arch x64 host (24 CPUs). The JSON records source commit `4b014a42`, pinned V compiler commit, runner image, and verified server/TUI SHA-256 hashes. This is a small trend sample measured on one host, not an Ubuntu-runner timing or a general performance claim.

## Remaining product gaps

- macOS/Windows measured TUI samples from their own pinned runners; the Linux
  CI-built sample above was measured on a local host.
- Broader interactive coverage beyond the short standalone smoke path
  (approvals, streaming, MCP OAuth browser open, long diffs).
- See also [`../IMPLEMENTATION_PLAN.md`](../IMPLEMENTATION_PLAN.md) and
  [`../COMPETITIVE_SOURCE_STUDY.md`](../COMPETITIVE_SOURCE_STUDY.md).
