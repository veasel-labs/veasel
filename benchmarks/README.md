# Benchmarks

`store_benchmark_test.v` measures a repeatable SQLite session round trip:
create a session, transactionally persist a user/assistant exchange, and read
back its messages and events. It uses V's production compiler mode and an
in-memory SQLite database so the sample isolates application/database work
from filesystem and network latency.

Build the release binary first, as documented in
[`../docs/V_BUILD_PROFILE.md`](../docs/V_BUILD_PROFILE.md). Then run the
benchmark from the repository root with the same compiler and production
profile:

```sh
VEASEL_RUN_BENCHMARK=1 VJOBS=1 \
VEASEL_BENCH_BUILD_MANIFEST=dist/build.json \
VEASEL_BENCH_COMMAND='v -cc gcc -prod test store_benchmark_test.v' \
VEASEL_BENCH_OUTPUT=/tmp/session-store.json \
  v -cc gcc -prod test store_benchmark_test.v
```

Set `VEASEL_BENCH_ITERATIONS` to an integer from 1 to 10,000; the default is
500. Output is one JSON record with operations, iteration count, throughput,
elapsed time, compile command, and release-build provenance. GitHub Actions
retains the record for CI runs. Release binaries and this benchmark use the
same platform compiler and `-prod` profile; see
[`../docs/V_BUILD_PROFILE.md`](../docs/V_BUILD_PROFILE.md). Compare runs on the
same operating system, architecture, compiler, and hardware; hosted-runner
timings are noisy and are reports, not a pass/fail performance promise. The
benchmark only measures in-memory SQLite session work. It is not evidence of
agent task success, model efficiency, or end-to-end latency.

## Local CLI startup comparison

`cli-startup.mjs` compares process startup and argument handling for Veasel
Code, Claude Code, Codex, OpenCode, and Pi using only `--version` and `--help`.
It makes no model requests. The report includes each installed CLI version and
minimum, median, p95, maximum, and mean wall time. Samples rotate command order
to reduce ordering bias; use the same machine, OS, power state, and sample count
when comparing later runs.

Download and verify the Veasel release binary, then run:

```sh
VEASEL_BIN=/path/to/veasel VEASEL_BENCH_SAMPLES=30 VEASEL_BENCH_WARMUPS=3 \
  node benchmarks/cli-startup.mjs --output cli-startup.json
```

All non-Veasel CLIs must be on `PATH`. Missing or failing commands remain in
the JSON report with zero or partial samples and a failure count. On Linux the
harness also samples peak RSS via
`resource.getrusage(RUSAGE_CHILDREN).ru_maxrss` (kilobytes) for each command
unless `VEASEL_BENCH_RSS=0`. Set `VEASEL_BENCH_RSS_SAMPLES` to control RSS
sample count (default: min(wall samples, 15)). This narrow measurement covers
process launch and CLI parsing only. It does not measure interactive
rendering, model latency, coding-task quality, token cost, idle-server memory,
or end-to-end productivity and cannot establish that one coding agent is
faster overall.

### Recorded local baselines

| Report | Veasel binary | Notes |
|---|---|---|
| [`reports/cli-startup-linux-x64-2026-10-18.json`](reports/cli-startup-linux-x64-2026-10-18.json) | `0.58.0-next.0` | Wall time (30 samples) + peak RSS (`ru_maxrss`) for `--version`/`--help` |
| [`reports/cli-startup-linux-x64-2026-10-15.json`](reports/cli-startup-linux-x64-2026-10-15.json) | `0.41.0-next.0` | Wall time (30 samples) + peak RSS (`ru_maxrss`) for `--version`/`--help` |
| [`reports/cli-startup-rss-linux-x64-2026-10-15.json`](reports/cli-startup-rss-linux-x64-2026-10-15.json) | `0.41.0-next.0` | Standalone RSS companion used while enriching the 2026-10-15 report |
| [`reports/cli-startup-linux-x64-2026-10-12.json`](reports/cli-startup-linux-x64-2026-10-12.json) | `0.13.0-next.0` | Historical wall-time-only baseline |

2026-10-18 `--version` medians on one Linux x64 workstation (published
`0.58.0-next.0` binary; 30 samples, 0 failures for every CLI):

| CLI | p50 wall | p50 RSS |
|---|---:|---:|
| Veasel Code 0.58.0-next.0 | 2.939 ms | 14188 kB (~13.9 MiB) |
| Codex CLI 0.163.0 | 9.355 ms | 27836 kB |
| Claude Code 2.1.296 | 9.962 ms | 36188 kB |
| OpenCode 2.0.27 | 128.711 ms | 78032 kB |
| Pi 0.85.1 | 257.936 ms | 108036 kB |


These are single-workstation CLI-only baselines, not a cross-machine benchmark
or a comparison of interactive TUI readiness and coding-agent performance.
Repeat after changes before making broader performance claims.

## Local TUI startup + PTY connected

`tui-startup.mjs` measures packaged `veasel-tui` `--version`/`--help` wall time
and Linux RSS, plus PTY time-to-connected against an isolated `veasel serve`
(visible markers `connected`, `SESSIONS`, `VEASEL`). It makes no model requests.

```sh
VEASEL_TUI_BIN=veasel-tui VEASEL_BIN=veasel \
VEASEL_BENCH_SAMPLES=15 VEASEL_BENCH_WARMUPS=2 VEASEL_TUI_PTY_SAMPLES=5 \
  node benchmarks/tui-startup.mjs --output tui-startup.json
```

`tui-journey.mjs` goes one step further: real keystrokes in the PTY —
connected home → `/help` Help dialog → `Esc` → home again — with per-step
wall times and the visible screen tail on failure. It proves one keyboard
journey on the host that runs it, nothing more.

```sh
VEASEL_TUI_BIN=veasel-tui VEASEL_BIN=veasel \
  node benchmarks/tui-journey.mjs --output tui-journey.json
```

## Real-repo repository-map recall

`repo-map-recall.mjs` measures context quality, not speed: labeled
natural-language queries against a real checkout, served through the public
API (`POST /v1/sessions` + `GET /v1/sessions/{id}/workspace/map`), checking
whether the file a human would open first lands in the top 3 / top 10 ranked
paths. It needs a local checkout of the target repo; it makes no model
requests.

```sh
VEASEL_BIN=veasel node benchmarks/repo-map-recall.mjs \
  /path/to/aider benchmarks/repo-map-recall-aider-cases.json
```

Recorded on the Aider checkout (685 files scanned, 12 KiB map budget),
2026-10-19: before the symbol-flooding fix, recall@3 was 2/6 and recall@10
3/6 (a large test file ranked #1 for unrelated queries). After capping
per-file symbol relevance and demoting static important-file bonus below
hint relevance: recall@3 4/6, recall@10 5/6, with four expected files at #1.

Same measurement on the mini-swe-agent checkout (221 files scanned,
`repo-map-recall-mini-swe-agent-cases.json`), confirmed against the
published v0.64.2 binary: recall@3 2/4, recall@10 4/4. Before the fix the
same binary line scored recall@3 0/4 and recall@10 1/4 — for "the main
agent loop" query it ranked `.gitignore`, `AGENTS.md`, and `LICENSE.md`
as the top 3, which is the static-importance swamping in the wild.

Same measurement on the SWE-agent checkout (407 files scanned,
`repo-map-recall-swe-agent-cases.json`), confirmed against the published
v0.64.2 binary: recall@3 5/6, recall@10 6/6, with four expected files
at #1.

### Recorded local TUI baseline

| Report | Binary | Notes |
|---|---|---|
| [`reports/tui-startup-linux-x64-2026-10-15.json`](reports/tui-startup-linux-x64-2026-10-15.json) | `0.41.0-next.0` | Linux x64 workstation: CLI wall+RSS (15 samples) and PTY connected (5 samples) |
| [`reports/tui-startup-linux-x64-2026-10-19.json`](reports/tui-startup-linux-x64-2026-10-19.json) | `0.59.0-next.0` | Linux x64 workstation: CLI wall+RSS (15 samples) and PTY connected (5 samples, per-sample results recorded) |

2026-10-15 medians on one Linux x64 workstation (`7.2.9-arch1-1`):

| Probe | p50 |
|---|---:|
| `veasel-tui --version` | 41.1 ms (≈50.4 MiB RSS) |
| `veasel-tui --help` | 41.9 ms (≈50.3 MiB RSS) |
| PTY → connected home | 70.0 ms |

2026-10-19 medians on the same class of workstation (`7.2.9-arch1-1`,
published `0.59.0-next.0` tarball):

| Probe | p50 |
|---|---:|
| `veasel-tui --version` | 53.0 ms (≈38.0 MiB RSS) |
| `veasel-tui --help` | 53.3 ms (≈38.2 MiB RSS) |
| PTY → connected home | 87.4 ms |

The PTY probe now records every sample (elapsed time or the exact error,
including the visible screen tail on a 12 s timeout) in
`ptyConnectedMs.samples`; earlier reports only kept a failure count, which
hid why a sample failed. An intermittent single-sample PTY timeout
(roughly 1 in 25 samples on this workstation) is under investigation and
is not hidden by the summary statistics.

Single-workstation evidence only. See
[`../docs/compatibility/tui-interactive-smoke.md`](../docs/compatibility/tui-interactive-smoke.md).
