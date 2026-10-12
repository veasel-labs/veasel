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

Only successful operations currently export a complete trajectory. Failed or
cancelled operations do not yet preserve partial traces. File-edit, shell, and
MCP proposals continue to require their normal explicit approval; this command
does not enable autonomous side effects or a Harbor task-evaluation workflow.
Therefore this export is an interoperability prerequisite, not a claim that
Veasel is already a Harbor agent.

## Benchmark status

The local SQLite and process-startup microbenchmarks measure deterministic
runtime paths only. Harbor, Harbor Index, Terminal-Bench, SWE-bench, ProgramBench,
and CodeClash task evaluations have not been run or submitted. Public dashboard
results must remain empty until there are versioned, reproducible measurements.

Before adding context indexes, parallel tool calls, or automatic compaction,
benchmark fixed fixtures and record both correctness and resource use. Every
optimization should have a reproducible baseline and post-change measurement.
