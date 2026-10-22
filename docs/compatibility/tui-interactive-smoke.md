# TUI interactive smoke — platform matrix

**Harness:** [`scripts/standalone-tui-smoke.py`](../../scripts/standalone-tui-smoke.py)
**Local keyboard exercise:** [`tui/scripts/exercise-keyboard.py`](../../tui/scripts/exercise-keyboard.py)
**Study date:** 2026-10-22

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
| Windows x64 | `windows-latest` (V backend job) | Pending CI | Native ConPTY driver in `scripts/windows_conpty.py` |

The same journey runs through Unix PTY on Linux/macOS and native ConPTY on
Windows. A green Windows job is required before claiming the new interactive
path is verified; this host cannot execute ConPTY locally.

## Windows acceptance covered by CI

The Windows CI job builds `dist/veasel.exe` and `dist/veasel-tui.exe`, starts
the backend in isolated temporary state, and drives the packaged client in a
100×24 pseudoconsole. The shared smoke checks:

1. Start the backend on loopback and confirm `GET /v1/health`.
2. Launch `veasel-tui.exe` in Windows Terminal (or ConPTY-capable host).
3. Confirm home chrome: connected status, `SESSIONS`, `VEASEL` brand.
4. Press `s` and confirm `MODEL SETTINGS` opens; Tab cycles provider scopes.
5. Esc returns without crashing; quit cleanly.
The Python driver uses `CreatePseudoConsole`, Win32 pipes, and
`PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`; WSL/Git Bash are not used as a proxy for
ConPTY. Record CI failures with the visible terminal tail emitted by the smoke.

## Measured Linux TUI baselines (this host only)

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

## Remaining product gaps

- macOS/Windows measured TUI baselines (Linux only above).
- Broader interactive coverage beyond the short standalone smoke path
  (approvals, streaming, MCP OAuth browser open, long diffs).
- See also [`../IMPLEMENTATION_PLAN.md`](../IMPLEMENTATION_PLAN.md) and
  [`../COMPETITIVE_SOURCE_STUDY.md`](../COMPETITIVE_SOURCE_STUDY.md).
