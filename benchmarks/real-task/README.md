# Real-task benchmark cases

This directory holds versioned coding tasks and a standard-library runner. It
starts small: `website-173` pins the repository commit, exact prompt hash,
Qwen3:8b model digest, Ollama version, CUDA/GPU, permissions, context/output
budgets, wall limit, and a memory safety floor. It has Veasel and OpenCode
launch adapters for the same case. The runner rejects drift or insufficient host resources before starting
an attempt. Resource aborts and timeouts are distinct outcomes and are never
scored as coding failures.

## Prepare and preflight

Use a disposable checkout at the case's exact base commit. Keep it clean and
make sure its `origin` URL matches the case. Start the exact Ollama model tag
locally; the preflight queries `/api/tags`, `/api/version`, and `/api/ps` and
compares the model digest and Ollama version. For this CUDA case it also
requires the pinned model to be loaded at the pinned context with all model
weights in VRAM; seeing an NVIDIA device alone is insufficient. This initial
case is specific to the RTX 3060 CUDA run. Other hardware needs a separately
versioned case before its results can be compared.

```sh
python3 benchmarks/real-task/run.py preflight \
  --workspace /path/to/disposable/website-checkout \
  --data-dir /benchmark/state
```

The website CUDA case requires at least 4.5 GiB available host RAM. A
4096-context CUDA placement probe used 5.6 GB of RTX 3060 VRAM and reduced host
available RAM by about 0.8 GiB; the 4.5 GiB floor leaves over 1 GiB of measured
host headroom for the agent and task tools. Swap is recorded, but is not
required while the pinned model weights and context fit in VRAM. The runner
continues sampling RAM and swap once per second and aborts below the RAM floor.
A failed preflight exits with status 2 and lists the unmet checks.

## Run Veasel

Run only inside an externally isolated, disposable task environment with no
host home mounts, unrelated secrets, or writable paths beyond the task checkout
and isolated Veasel state. The confirmation flag records that operator
assertion; it does not create or verify a sandbox. The local Veasel provider
configuration must already point at the pinned local model. No paid API is
used.

```sh
python3 benchmarks/real-task/run.py run \
  --workspace /path/to/disposable/website-checkout \
  --data-dir /benchmark/state \
  --artifacts /path/to/private-attempt-artifacts \
  --sandbox-confirmed
```

The runner sets the pinned context and output limits itself, samples available
RAM and swap once per second, and stops the client if either drops below the
case floor. Private ATIF and client logs stay in the chosen artifact directory;
do not publish them without reviewing and sanitizing source, prompts, and tool
I/O. `attempt.json` records versions, hashes, timing, resource samples, and one
of `completed`, `resource_aborted`, `timeout`, or `agent_error`. A completed
turn is still **unscored** until an independent reviewer checks the expected
diff and task-specific tests against the external oracle.

## Run the OpenCode baseline

Reset the same checkout to the same pinned base commit and use the same local
Ollama endpoint/model and disposable sandbox. OpenCode is pinned at v2.2.5;
the runner writes a private provider config with the same endpoint and 4096 / 2048
context/output limits. Its Build agent allows only repository read/edit/search/list
and shell tools; web, subagents, MCP, and external-directory access are denied.
The runner starts OpenCode from the pinned checkout and uses the documented
standalone, model, agent, auto-approval, and JSON event options ([CLI docs](https://opencode.ai/docs/cli/commands),
[permissions](https://opencode.ai/docs/permissions/), [Ollama config](https://opencode.ai/docs/providers/)).
The preflight rejects repository or system OpenCode config files that could
override the pinned model/provider setup.

```sh
python3 benchmarks/real-task/run.py preflight --agent opencode \
  --workspace /path/to/disposable/website-checkout \
  --data-dir /benchmark/opencode-state
python3 benchmarks/real-task/run.py run --agent opencode \
  --workspace /path/to/disposable/website-checkout \
  --data-dir /benchmark/opencode-state \
  --artifacts /path/to/private-opencode-attempt \
  --sandbox-confirmed
```

Run Veasel and OpenCode as separate attempts from reset workspaces. Do not run
them concurrently: they share the same local model and host resource budget.
The reports pin task/model/settings, but a comparison is valid only after both
outcomes are externally scored against the same oracle.

## Current quality scoreboard

As of 2026-11-11, the only task in the corpus is website#173 at base
`184c7d8`, with the pinned Qwen3:8b digest, Ollama 0.40.15, CUDA on an RTX
3060, and prompt SHA-256
`5e2a8cede2b2f2736cfcda848294b1f488e1fdf43961bc4efa565282b0ea918e`.
The independent oracle is the merged website#173 patch plus repository checks
and responsive/accessibility behavior in the issue acceptance criteria.

| Agent/build | Outcome | Time | Independent task result | Classification |
|---|---|---:|---|---|
| Veasel `v0.69.14-next.0` | completed | 34.1 s | 0 edits; workspace remained clean | failed to follow the coding request |
| Veasel source `986fde4` built with V `b0ceb9b` | completed | 37.1 s | 0 edits; workspace remained clean | failed to follow the coding request |
| OpenCode `2.2.5` | resource-aborted | 57.4 s | 0 edits; workspace remained clean | unscored: available RAM fell below the 4.5 GiB safety floor |
| Veasel search-first fix `e836100` built with V `b0ceb9b` | resource-aborted | 1.1 s | no model output or workspace changes | unscored: available RAM fell below the 4.5 GiB safety floor |
| Veasel PR #614 head `f26b2fd` built with V `b0ceb9b` | completed | 6.1 s | 0 edits; clean workspace | failed: exact multiword search returned no matches and the agent stopped |
| Veasel multiword-search fallback | resource-aborted | 13.2 s | no scored result; workspace remained clean | unscored: RAM crossed the 4.5 GiB safety floor before a completed turn |

The three completed Veasel attempts each count as a verified task failure: the disposable
workspaces were checked after the run and contained no patch. In the current
source run, Qwen3:8b first summarized unrelated TUI controls, then searched
generic terms and repository guidance instead of the Astro navigation source.
The OpenCode run is not a quality comparison: it was stopped by the resource
guard after RAM dropped below the case floor, after two exploratory tool calls.
The first replay after the search-first orchestration change was stopped by the
guard before model output when available RAM fell to 4.47 GiB. A later PR #614
head attempt completed in 6.1 seconds, made one literal multiword search, then
returned without a source read or edit. The replay after the fallback change was
resource-aborted below the 4.5 GiB floor and remains unscored. Therefore this
case has **0/3 verified Veasel successes, 0 verified OpenCode successes, and
no scored head-to-head result**. These are observations from one task and
one local hardware setup, not a general quality or speed claim.

Full trajectories and logs remain private under the operator's local benchmark
artifact directory. No raw traces or workspace source are included here. Sanitized
summaries record the [PR #614 search failure](../reports/real-task-attempt-website-173-post-614-search-failure-2026-11-11.json)
and the [unscored fallback replay](../reports/real-task-attempt-website-173-post-fallback-resource-abort-2026-11-11.json).

This first version samples host available RAM and swap. It does not yet collect
CPU, process/GPU peak memory, or provider-reported token usage, so reports are
not complete comparative benchmark records and cannot support efficiency or
speed claims.

All three attempts used the same task, prompt hash, model digest, context, and
output limits; the Veasel attempts also passed the recorded GPU-placement and
4.5 GiB host-memory preflight. The corrected OpenCode command was used for the
resource-aborted result. The harness changes have landed; reproduce future attempts from a clean main
checkout and keep the case revision pinned. Do not
compare runs produced by a different case revision or prompt hash.
