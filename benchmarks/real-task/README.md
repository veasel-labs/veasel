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

The website CUDA case requires at least 5.75 GiB available host RAM at
preflight, after the pinned model is loaded, and keeps a 4.5 GiB runtime floor.
Two guarded attempts started with 5.60 and 5.62 GB available, then crossed the
runtime floor within 11–14 seconds; the latest reached 4.39 GiB. The higher
preflight threshold reserves about 1.25 GiB for agent startup and leaves margin
over the observed roughly 0.83 GiB decline. Swap is recorded, but is not
required while the pinned model weights and context fit in VRAM. During a run,
the runner continues sampling RAM and swap once per second and aborts below the
4.5 GiB floor. A failed preflight exits with status 2 and lists the unmet checks.

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

As of 2026-11-12, the only real coding task in the corpus is website#173 at
base `184c7d8`, using the pinned Qwen3:8b digest, Ollama 0.40.15, CUDA on an
RTX 3060, and prompt SHA-256
`5e2a8cede2b2f2736cfcda848294b1f488e1fdf43961bc4efa565282b0ea918e`. Across
30 attempts, the task has **0 verified successes** (4 resource-aborted and 3
timeouts). Resource-aborted runs are unscored. The independent oracle is the
merged website#173 patch, repository checks, and responsive/accessibility
behavior in that issue's acceptance criteria.

Recent completed attempts expose orchestration gaps: PR #614's agent searched
for the exact multiword phrase `docs sidebar navigation`, found no literal
match, and returned without reading or editing a file; a later run found the
sidebar source but proposed a replacement matching zero occurrences. The
multiword-search fallback merged in PR #615 has not yet earned a scored
real-model replay because subsequent runs were stopped by the 4.5 GiB runtime
floor. PR #617 now adds a 5.75 GiB startup reserve, but no replay under that
preflight has completed. See the [current product quality scoreboard](../QUALITY_SCOREBOARD.md)
for the attempt inventory and linked evidence.

The initial matched Qwen3:8b Veasel/OpenCode pair yielded no successful task
outcome for either agent; OpenCode had no usable tool trace. This is one
diagnostic pair, not enough evidence for a comparative quality or speed claim.
The separate synthetic sidebar-label calibration has two externally verified
successes in six attempts; it does not count as a website#173 success.
Full trajectories remain private under the local benchmark artifact directory.
On 2026-11-12, the official Veasel 0.74.0-next.0 Linux artifact and OpenCode
2.2.7 were also run against the same repository base, exact prompt, Muse Spark
1.3 Contributor model, context/output limits, and 330-second wall cap. Veasel
made an incomplete, inert button edit in 84.6 seconds; OpenCode made no edits
before timeout. Both failed the independent oracle. The sanitized report is
[`real-task-comparison-website-173-muse-2026-11-12.json`](../reports/real-task-comparison-website-173-muse-2026-11-12.json).
This was an exploratory manual replay: the checked-in runner still pins the
Ollama/CUDA Qwen case and does not yet reproduce this configured Muse run.
Peak RSS/CPU sampling was missed, so those measurements are explicitly absent.
Sanitized reports include the [PR #614 search failure](../reports/real-task-attempt-website-173-post-614-search-failure-2026-11-11.json),
the [resource-aborted post-fallback replays](../reports/real-task-attempt-website-173-post-fallback-resource-abort-2026-11-11.json),
and the [PR #615 startup abort](../reports/real-task-attempt-website-173-pr615-startup-resource-abort-2026-11-12.json).

The runner targets a one-second sampling cadence for host available RAM, swap,
agent process-tree RSS and CPU time, and device-wide GPU memory. Sampling
overhead and actual sample timestamps are recorded. Sampled maxima are recorded
with scope notes: RSS may double-count shared pages, and GPU memory includes the
model server and any other GPU clients. These are sampled measurements, not
true process or device peaks. Attempt reports now capture Veasel's ATIF usage
summary and OpenCode's JSON `step_finish` token counters when present. Missing
counters remain `null`, not zero. OpenCode may omit a final `step_finish` event,
so its observed usage can be partial. Its reported cost is recorded separately
and can be zero for a local model without configured pricing; Veasel ATIF does
not export cost. These fields enable collection but do not establish comparable
efficiency or speed without scored, complete runs.

The case pins task, prompt hash, model digest, context, and output limits.
Recent resource-aborted attempts did not complete a coding turn and are not
counted as failures. Reproduce from a clean checkout at the pinned base and
keep the case revision fixed; outcomes from a different case revision or prompt
hash are not directly comparable.

## Explicit non-Ollama provider cases

The original `website-173` and `website-166` Ollama/CUDA cases remain pinned and
unchanged. A separate case can select a provider/model already supported by
Veasel through an explicit profile target. Never put API keys, bearer tokens,
or credential values in a case, prompt, command line, trace, or report.

```json
{
  "model": {
    "provider": "anthropic",
    "name": "claude-example-model",
    "context_tokens": 8192,
    "output_tokens": 2048
  },
  "provider_config": {
    "mode": "veasel-profile",
    "provider": "anthropic",
    "model": "claude-example-model",
    "base_url": "https://api.anthropic.com/v1",
    "credential": "saved-profile"
  }
}
```

The full case must still pin repository URL and base commit, prompt hash,
permissions, an independent oracle, and wall/resource budgets. Add the selected
profile to the isolated `--data-dir/model-settings.json` before preflight. Its
provider, exact model, and endpoint must match the case; its output cap must be
at least the requested output limit. The runner reports only whether a saved
credential exists, never the value. For a provider that intentionally needs no
key, set `credential` to `none`. The runner strips provider credential
environment variables before launch, so environment-only credentials do not
qualify as ready.

Preflight fails closed for missing/mismatched profiles, endpoints, saved
credentials, or insufficient output limits. It makes **no provider network
request**. `provider_live_readiness: not_probed` means remote model availability,
account entitlement, and credential acceptance remain unverified. A
non-Ollama case currently supports the Veasel runner only; OpenCode comparator
preflight rejects it instead of silently changing the baseline. Keep a separate
case ID for every provider/model target; don't compare runs with different
provider, exact model, prompt, repository base, or budgets.

Veasel receives the case context/output limits. Attempt reports include the
provider/model target, declared budgets, and provider-reported token usage when
available; missing usage stays unknown, not zero. An optional `max_cost_usd`
may record an operator-approved budget and is included in the attempt report,
but the runner does **not** enforce a monetary ceiling or guarantee provider
side accounting. Do not run a paid-provider case until spend is authorized and
provider-side limits are independently established. A completed turn remains
unscored until the independent oracle verifies the patch and tests.
