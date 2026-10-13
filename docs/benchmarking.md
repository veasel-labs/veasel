# Benchmarking Veasel Code

Benchmark task resolution separately from deterministic runtime costs. Never
compare agents unless the report records the benchmark and dataset revisions,
agent versions, model/provider, execution limits, environment image, trial count,
raw task outcomes, and uncertainty. Keep same-model harness comparisons separate
from best-product comparisons. Do not submit a benchmark result until its
official submission requirements and artifact policy have been checked.

## Headless ATIF export

`veasel run` can export a successful headless turn as an ATIF v1.8 trajectory:

```sh
veasel run --prompt 'Fix the failing test' --workspace . \
  --trace-file artifacts/trajectory.json --json
```

The deterministic OpenAI-compatible provider path was exercised through the
real V server and CLI; its trajectory passed Harbor 0.24.0's validator at
`dc933be707feafbb9efcdf092cb8a0e391332617`. Linux CI now checks out that exact
Harbor revision and runs its trajectory validator against a real smoke-generated
trace. It installs only the pinned Pydantic dependency needed by Harbor's ATIF
models, rather than the complete benchmark runtime. The trace is validated in CI
but not uploaded as a public artifact because it contains workspace content.

Trace collection is disabled unless `--trace-file` is supplied. The exported
trajectory contains the full model-visible conversation passed to the turn: with
`--session`, this includes earlier stored user and assistant messages as well as
system instructions and the current prompt. It also includes model responses,
provider tool-call arguments, and tool observations. These may include private
instructions, source, or tool output; store the file as a sensitive artifact and
sanitize it before publication. The CLI creates the trace with owner-only file
permissions on platforms that support them. The current provider interfaces do
not expose authoritative usage or cost for every model,
so those values are omitted and marked unavailable in the trace metadata. Never
derive costs from a guessed token count or a mutable pricing page.

Successful operations export a complete trajectory with
`extra.outcome: "completed"`. When trace collection is enabled, a failed or
cancelled turn also preserves the steps captured before the failure as a
partial trajectory with `extra.outcome` set to `"failed"` or `"cancelled"`;
the operation result endpoint returns it, and `veasel run --trace-file`
writes it alongside the failed result. When a provider adapter reports token
usage, trajectories carry `extra.token_usage: "reported"` and a `final_metrics`
object with the summed prompt, completion, and total token counts across the
turn's model calls; cost remains marked unavailable because providers do not
return authoritative prices. File-edit,
shell, and MCP proposals continue to require their normal explicit approval
by default.

## Harbor installed agent

`benchmarks/harbor/veasel_agent.py` is a custom Harbor `BaseInstalledAgent`
adapter. It downloads an exact Veasel Linux x86_64 release, verifies its
SHA-256 against the release checksum manifest, maps Harbor's model/provider
selection to Veasel's supported providers, runs the headless task command, and
stores the ATIF trajectory at Harbor's agent log path. Provider-reported token
usage and cost remain unavailable and are not estimated.

The adapter requires an exact release version and Harbor's custom-agent
interface:

```sh
harbor run \
  --dataset terminal-bench@<pinned-version> \
  --agent benchmarks.harbor.veasel_agent:VeaselCode \
  --ak veasel_version=<exact-veasel-version> \
  --model <provider/model>
```

Harbor does not expose a universal `--n-trials` option. For repeated trials,
use the benchmark's supported task/job configuration and run each trial from a
reset task environment with a separately recorded job configuration; do not
misuse retry attempts as independent trials.

The adapter's `--autonomous` mode applies workspace edits and runs shell
commands without human approval. It is enabled only for a task request when
the server was started with `VEASEL_ALLOW_AUTONOMOUS_EXECUTION=1`; the normal
TUI and headless behavior stay approval-gated. This environment flag is an
authorization opt-in, **not a sandbox**. Harbor must run the agent inside an
isolated, disposable task environment with no host mounts, no unrelated secrets,
and only the required model credential. The adapter installs Bubblewrap, and
Veasel additionally runs autonomous Linux shell subprocesses with a read-only
host filesystem, the task workspace writable, common private/runtime paths
hidden, and networking isolated. These layers do not replace the benchmark
environment's isolation. Do not enable autonomous execution against a developer
workspace.

The custom adapter is locally implemented and has not been merged into Harbor.
The upstream project asks contributors to initiate design discussions before
changes to interfaces or core logic and requires the human author to write the
first and final PR drafts. External Harbor inclusion and benchmark results are
therefore not claimed. No paid benchmark run has been started.

### Reproduce the deterministic installed-agent smoke

The one-task fixture at `benchmarks/harbor/smoke-task` exercises the complete
Harbor `harbor run` path, including verified release installation, provider
selection, streamed tool calls, autonomous edit application inside the Harbor
task container, verification, and ATIF export. It uses an in-container fixed
OpenAI-compatible fixture and a dummy key, so it does not call or bill an LLM
provider. Docker and network access are still needed to build the task image
and fetch the exact Veasel release.

```sh
VEASEL_VERSION=<exact-published-release> benchmarks/harbor/smoke.sh
```

The first successful run used Veasel `0.20.0-next.0`, Harbor `0.24.0`, and
returned reward `1.0` for one completed trial. Harbor validated the resulting
four-step `ATIF-v1.8` trajectory. This smoke proves adapter and artifact
plumbing only; it is not a capability score, a performance result, or a public
benchmark submission. Inspect local job artifacts before sharing them because
trajectories may contain prompts and workspace data.

## Benchmark status

The local SQLite and process-startup microbenchmarks measure deterministic
runtime paths only. The Harbor adapter's deterministic one-task smoke has
passed, but it has not been exercised against a paid or public task dataset.
Harbor Index, Terminal-Bench, SWE-bench, ProgramBench, and CodeClash task
evaluations have not been run or submitted.
Public dashboard results must remain empty until there are versioned,
reproducible measurements.

Before adding context indexes, parallel tool calls, or automatic compaction,
benchmark fixed fixtures and record both correctness and resource use. Every
optimization should have a reproducible baseline and post-change measurement.
