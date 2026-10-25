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

## Repository-map ranking microbenchmark

`repository_map_benchmark_test.v` measures cross-reference ranking over a fixed
256-file, 1 MiB synthetic source corpus. Fixture construction is outside the
timed region; each result includes 2 warmups, 11 raw samples, p50/p90 elapsed
time, a score checksum, compiler version, source revision, and host platform.
It is opt-in and does not add work to ordinary test runs:

```sh
VEASEL_RUN_REPOSITORY_MAP_BENCHMARK=1 \
VEASEL_BENCH_COMPILER_VERSION='V <version>' \
VEASEL_BENCH_SOURCE_REVISION='<git-revision>' \
VEASEL_BENCH_OUTPUT=/tmp/repository-map-ranking.json \
VEASEL_BENCH_BUILD_PROFILE='gcc -prod' \
  v -cc gcc -prod test repository_map_benchmark_test.v
```

Compare a change with its parent on the same machine using the same pinned V
compiler. This isolates ranking cost, not filesystem walking, symbol extraction,
or full API latency; it does not establish task success or end-to-end speed.
The 2026-10-25 `gcc -prod` comparison of the PR base (`38ea5b5`) and code at
candidate revision (`ebb45d2`) measured p50 3.038 ms → 2.347 ms (22.75%
lower) and p90 3.229 ms → 2.505 ms (22.42% lower), with identical score
checksums. Both revisions used the same pinned V compiler, GCC profile, and
AMD Ryzen 9 5900X host. Raw samples and the full compiler pin are in
[`reports/repository-map-ranking-linux-x64-2026-10-25.json`](reports/repository-map-ranking-linux-x64-2026-10-25.json).
The earlier 2026-10-24 measurement remains in
[`reports/repository-map-ranking-linux-x64-2026-10-24.json`](reports/repository-map-ranking-linux-x64-2026-10-24.json).
These are synthetic Linux x64 measurements, not a general performance claim.

The follow-up lexical-hint cache was measured on the same fixture and host:
revision `c1d12b2` → `ab70e3d` reduced p50 2.256 ms → 2.175 ms (3.59%)
and p90 2.325 ms → 2.195 ms (5.59%), with the same score checksum. It
precomputes normalized, deduplicated query terms once instead of allocating a
per-file deduplication map, and compares already-normalized path terms without
creating lowercase copies in the hot loop. Raw samples and environment details are in
[`reports/repository-map-ranking-lexical-cache-linux-x64-2026-10-25.json`](reports/repository-map-ranking-lexical-cache-linux-x64-2026-10-25.json).
This remains a synthetic ranking-only measurement, not an end-to-end or task-quality claim.

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
The Solid entry handles `--help` and `--version` before importing the UI
client; [`reports/tui-startup-linux-x64-2026-10-23.json`](reports/tui-startup-linux-x64-2026-10-23.json)
records a same-host comparison against the published release.

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

`tui-echo-latency.py` measures composer key echo through a pyte screen
emulator (OpenTUI renders frame diffs, so raw PTY byte growth is not a
valid signal): per-keystroke time until the typed text is visible.
Baseline on v0.64.2-next.0 binaries, 100x24: connect 90-96 ms, echo
p50 16 ms, p95 17-18 ms, 16/16 keys — one 60 fps frame. Requires
`pip install pyte`; it spawns its own isolated server.

```sh
VEASEL_TUI_BIN=veasel-tui VEASEL_BIN=veasel \
  python3 benchmarks/tui-echo-latency.py
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

Add `--output benchmarks/reports/<name>.json` to save each query's ranked paths
and position with the Veasel version, source revision and dirty-diff digest,
binary SHA-256, target repository revision, and recall totals. Set
`VEASEL_COMPILER_VERSION` and `VEASEL_BUILD_FLAGS` when building locally so the
report records those too.

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

The bounded lexical-ranking implementation described here was measured on the
same pinned research checkouts listed in the workspace's
`research/refs/REVISIONS.md`, using the same cases and 12 KiB budget. On the
Linux x64 workstation, recall was:

| Checkout | Recall@3 | Recall@10 | Change from prior recorded baseline |
|---|---:|---:|---|
| Aider (685 files) | 4/6 | 6/6 | @3 unchanged; @10 +1 |
| mini-swe-agent (221 files) | 3/4 | 4/4 | @3 +1; @10 unchanged |
| SWE-agent (407 files) | 6/6 | 6/6 | @3 +1; @10 unchanged |

The lexical signal reuses source text already read for declaration extraction,
caps query-term contribution, normalizes common `-ing` query words such as
"parsing" to code identifiers such as `parse_args`, and demotes test paths for
behavior queries. The latest measured change strengthens the high-confidence
`argument`/`args` filename alias: Aider recall@3 stayed 4/6 while recall@10
rose from 5/6 to 6/6, placing `aider/args.py` at rank 6 for the command-line
parsing query. mini-swe-agent stayed at 3/4 and 4/4; SWE-agent stayed at 6/6
and 6/6. These small labeled sets show one additional top-10 hit and no
aggregate regression; they do not establish broad semantic retrieval quality.
The per-query results and run fingerprints are checked in:
[`Aider`](reports/repo-map-recall-aider-2026-10-23.json),
[`mini-swe-agent`](reports/repo-map-recall-mini-swe-agent-2026-10-23.json),
and [`SWE-agent`](reports/repo-map-recall-swe-agent-2026-10-23.json).

A follow-up implementation-bias change demotes unrequested test files and
applies a small penalty to package indexes only when their source is entirely
imports/re-exports. Executable package modules remain eligible. The penalty is
disabled for explicit export/index/entrypoint and test queries. On the same
pinned checkouts and cases, mini-swe-agent improved from 3/4 to 4/4 recall@3;
its `litellm_model.py` moved from rank 4 to rank 2. Aider remained 4/6 at recall@3 and 6/6 at recall@10;
`aider/args.py` moved from rank 6 to rank 5, while the history-formatting miss
remains at rank 4. SWE-agent stayed 6/6 at both cutoffs. This is one additional
top-three hit across these small labeled sets, with no aggregate regressions;
it does not establish general semantic retrieval quality. Candidate source
fingerprints and per-query rankings are recorded in the
[`Aider`](reports/repo-map-recall-aider-2026-10-23-implementation-bias.json),
[`mini-swe-agent`](reports/repo-map-recall-mini-swe-agent-2026-10-23-implementation-bias.json),
and [`SWE-agent`](reports/repo-map-recall-swe-agent-2026-10-23-implementation-bias.json)
reports.

A filename-alias follow-up raises the explicit `argument`/`args` lexical match
while keeping exact basename matches stronger. On the same pinned checkouts,
Aider improved from 5/6 to 6/6 recall@3: `aider/args.py` moved from rank 6 to 3
and `aider/history.py` stayed at rank 1. mini-swe-agent remained 4/4 and
SWE-agent 6/6 at recall@3; all three remained perfect at recall@10. This is a
small labeled retrieval check, not a broad quality or task-completion claim.
The candidate binary hash, source diff fingerprint, revisions, and per-query
rankings are recorded in [`Aider`](reports/repo-map-recall-aider-2026-10-23-alias-priority.json),
[`mini-swe-agent`](reports/repo-map-recall-mini-swe-agent-2026-10-23-alias-priority.json),
and [`SWE-agent`](reports/repo-map-recall-swe-agent-2026-10-23-alias-priority.json).

To cover monorepos larger than the previous lexical walk cutoff, RepoMap now
scores up to 20,000 metadata-only paths, ranks the best 2,000, and retains the
existing source-read ceilings of 800 files and 8 MiB. Candidate sorting uses
V's `sort_with_compare` rather than quadratic insertion sort. On the pinned
OpenCode checkout (8,502 paths scanned), the three labeled cases moved from
0/3 to 3/3 recall@10; recall@3 is 1/3. The full local case run took about 8.8 s
versus 8.0 s for the previous 2,000-path cutoff. Pi remained 2/3 at recall@3
and 3/3 at recall@10 (1,953 paths; about 8.2 s versus 8.6 s). These timings
include server and harness startup and are not per-query latency. Results and
case definitions are in [`OpenCode cases`](repo-map-recall-opencode-cases.json),
[`OpenCode report`](reports/repo-map-recall-opencode-2026-10-23.json),
[`Pi cases`](repo-map-recall-pi-cases.json), and
[`Pi report`](reports/repo-map-recall-pi-2026-10-23.json). Together with the
unchanged Aider, mini-swe-agent, and SWE-agent runs above, the current candidate
hits 19/22 cases at recall@3 and 22/22 at recall@10 across these five small
curated samples. This measures file retrieval only, not coding-task success or
general semantic-search quality.

A path-specificity follow-up adds a bounded bonus when a path matches multiple
distinct exact query terms. This helps compound implementation names such as
`tool/plugin/subagent.ts` outrank files matching only the generic `tool` term,
while keeping single-word filename weight low enough that documentation paths
do not outrank high-confidence `argument`/`args` aliases. On the same five
checkouts and case sets, Aider stayed 6/6, mini-swe-agent 4/4, SWE-agent 6/6,
Pi 2/3, and OpenCode improved from 1/3 to 2/3 at recall@3; all five stayed at
22/22 recall@10. This raises the aggregate to 20/22 at recall@3 on the same
small curated sample, not a general semantic retrieval or task-success claim.
Reports include ranked paths, source fingerprints, and upstream revisions for
[Aider](reports/repo-map-recall-aider-2026-10-23-path-specificity.json),
[mini-SWE-agent](reports/repo-map-recall-mini-swe-agent-2026-10-23-path-specificity.json),
[SWE-agent](reports/repo-map-recall-swe-agent-2026-10-23-path-specificity.json),
[OpenCode](reports/repo-map-recall-opencode-2026-10-23-path-specificity.json),
and [Pi](reports/repo-map-recall-pi-2026-10-23-path-specificity.json).

Generic basenames such as `job.ts` and `lifecycle.ts` no longer receive the
same exact-file bonus as specific names. This fixes OpenCode's
"subagent job lifecycle resume" query: `packages/core/src/session/subagent-job.ts`
moved from rank 5 to rank 3, taking OpenCode from 2/3 to 3/3 at recall@3.
On the same five checkouts and case sets, Aider remained 6/6, mini-SWE-agent
4/4, SWE-agent 6/6, and Pi 2/3; aggregate recall@3 is now 21/22 while recall@10
remains 22/22. These are small, curated file-retrieval samples, not task-success
or general semantic-search evidence. Full rankings, source fingerprints, and
upstream revisions are recorded for [Aider](reports/repo-map-recall-aider-2026-10-23-generic-filename-specificity.json),
[mini-SWE-agent](reports/repo-map-recall-mini-swe-agent-2026-10-23-generic-filename-specificity.json),
[SWE-agent](reports/repo-map-recall-swe-agent-2026-10-23-generic-filename-specificity.json),
[OpenCode](reports/repo-map-recall-opencode-2026-10-23-generic-filename-specificity.json),
and [Pi](reports/repo-map-recall-pi-2026-10-23-generic-filename-specificity.json).
An ordered-compound follow-up gives a bounded boost when a basename contains
two query concepts in the same order, even when natural-language terms sit
between them (for example, “running many problem instances in batch mode” now
surfaces `sweagent/run/run_batch.py` above `batch_instances.py`). Matching a
gerund to its code stem (`running` → `run`) is allocation-free in the ranking
loop. Re-running the same five pinned checkouts and 22 labeled cases raised
recall@3 from 21/22 to 22/22; recall@10 remained 22/22. The reports record
the exact checkout revisions and rankings for [Aider](reports/repo-map-recall-aider-2026-10-25-ordered-compounds.json),
[mini-SWE-agent](reports/repo-map-recall-mini-swe-agent-2026-10-25-ordered-compounds.json),
[SWE-agent](reports/repo-map-recall-swe-agent-2026-10-25-ordered-compounds.json),
[OpenCode](reports/repo-map-recall-opencode-2026-10-25-ordered-compounds.json),
and [Pi](reports/repo-map-recall-pi-2026-10-25-ordered-compounds.json). This is
still a small retrieval sample, not evidence of general semantic-search quality
or end-to-end coding effectiveness.

### Recorded local TUI baseline

| Report | Binary | Notes |
|---|---|---|
| [`reports/tui-startup-linux-x64-2026-10-15.json`](reports/tui-startup-linux-x64-2026-10-15.json) | `0.41.0-next.0` | Linux x64 workstation: CLI wall+RSS (15 samples) and PTY connected (5 samples) |
| [`reports/tui-startup-linux-x64-2026-10-19.json`](reports/tui-startup-linux-x64-2026-10-19.json) | `0.59.0-next.0` | Linux x64 workstation: CLI wall+RSS (15 samples) and PTY connected (5 samples, per-sample results recorded) |
| [`reports/tui-startup-linux-x64-2026-10-23.json`](reports/tui-startup-linux-x64-2026-10-23.json) | `0.64.6-next.0` + optimized entry | Same-host published-vs-source comparison: 15 CLI and 15 PTY samples per build |

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

On 2026-10-23, the published `0.64.6-next.0` TUI measured 55.2 ms median for
`--version` and 55.4 ms for `--help`; its locally rebuilt entry measured
35.3 ms and 34.6 ms with the same Bun 1.4.2, host, backend and harness (15
samples, 2 warmups). Median RSS fell from 54,568 to 34,308 KiB for `--version`
and from 54,612 to 34,360 KiB for `--help`. PTY connected-home medians were
92.7 ms and 92.6 ms (15 samples each), so this change improves the short CLI
paths without claiming a faster interactive launch. The report records the
release and optimized binary hashes; it remains a single-host measurement, not
a render-FPS or coding-task benchmark.
