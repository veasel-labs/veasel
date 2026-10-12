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
the JSON report with zero or partial samples and a failure count. This narrow
measurement covers process launch and CLI parsing only. It does not measure
interactive rendering, model latency, coding-task quality, token cost, memory,
or end-to-end productivity and cannot establish that one coding agent is
faster overall.

### Recorded local baseline

The first 30-sample Linux x64 run is stored in
[`reports/cli-startup-linux-x64-2026-10-12.json`](reports/cli-startup-linux-x64-2026-10-12.json).
Its p50/p95 wall times were:

| CLI | `--version` p50 / p95 | `--help` p50 / p95 |
|---|---:|---:|
| Veasel Code 0.13.0-next.0 | 3.034 / 3.452 ms | 3.070 / 3.442 ms |
| Claude Code 2.1.285 | 10.582 / 12.331 ms | 86.912 / 93.886 ms |
| Codex CLI 0.160.0 | 9.446 / 10.963 ms | 9.834 / 10.828 ms |
| OpenCode 2.0.20 | 115.589 / 119.024 ms | 116.229 / 121.509 ms |
| Pi 0.85.1 | 273.052 / 283.435 ms | 377.940 / 389.034 ms |

This is one workstation's CLI-only baseline, not a cross-machine benchmark or
a comparison of interactive TUI readiness and coding-agent performance. Repeat
it after changes and collect interactive, memory, and task-quality measures
before making broader performance claims.
