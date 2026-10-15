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
| [`reports/cli-startup-linux-x64-2026-10-15.json`](reports/cli-startup-linux-x64-2026-10-15.json) | `0.41.0-next.0` | Wall time (30 samples) + peak RSS (`ru_maxrss`) for `--version`/`--help` |
| [`reports/cli-startup-rss-linux-x64-2026-10-15.json`](reports/cli-startup-rss-linux-x64-2026-10-15.json) | `0.41.0-next.0` | Standalone RSS companion used while enriching the 2026-10-15 report |
| [`reports/cli-startup-linux-x64-2026-10-12.json`](reports/cli-startup-linux-x64-2026-10-12.json) | `0.13.0-next.0` | Historical wall-time-only baseline |

2026-10-15 `--version` medians on one Linux x64 workstation:

| CLI | p50 wall | p50 RSS |
|---|---:|---:|
| Veasel Code 0.41.0-next.0 | 3.035 ms | 14160 kB (~13.8 MiB) |
| Claude Code 2.1.296 | 10.65 ms | 37704 kB |
| Codex CLI 0.162.1 | 9.744 ms | 26904 kB |
| OpenCode 2.0.27 | 134.325 ms | 76468 kB |
| Pi 0.85.1 | 265.764 ms | 107964 kB |


These are single-workstation CLI-only baselines, not a cross-machine benchmark
or a comparison of interactive TUI readiness and coding-agent performance.
Repeat after changes before making broader performance claims.
