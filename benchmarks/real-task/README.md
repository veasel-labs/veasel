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

Run only through an operator-managed isolation wrapper whose reviewed behavior
enforces a disposable task environment: no host home mounts or unrelated
secrets, and writable access limited to the task checkout and isolated Veasel
state/artifacts. The runner requires an absolute executable wrapper path and
its reviewed SHA-256, verifies that digest immediately before launch, and
passes the agent command through the wrapper using `-- <agent argv>`. A plain
confirmation flag is not accepted. The runner verifies wrapper identity, not
its sandbox semantics; the operator must review that the pinned wrapper applies
the intended filesystem, process, and network boundaries. The wrapper's digest
is recorded in `attempt.json`. It should `exec` the child so the monitored PID,
signals, and process tree continue to cover Veasel/OpenCode, and it must never
log command arguments or environment variables. The local Veasel provider
configuration must already point at the pinned local model. No paid API is
used.

```sh
ISOLATION_WRAPPER=/absolute/path/to/reviewed-isolation-wrapper
ISOLATION_WRAPPER_SHA256=<reviewed-64-character-sha256>
python3 benchmarks/real-task/run.py run \
  --workspace /path/to/disposable/website-checkout \
  --data-dir /benchmark/state \
  --artifacts /path/to/private-attempt-artifacts \
  --isolation-wrapper "$ISOLATION_WRAPPER" \
  --isolation-wrapper-sha256 "$ISOLATION_WRAPPER_SHA256"
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
ISOLATION_WRAPPER=/absolute/path/to/reviewed-isolation-wrapper
ISOLATION_WRAPPER_SHA256=<reviewed-64-character-sha256>
python3 benchmarks/real-task/run.py preflight --agent opencode \
  --workspace /path/to/disposable/website-checkout \
  --data-dir /benchmark/opencode-state
python3 benchmarks/real-task/run.py run --agent opencode \
  --workspace /path/to/disposable/website-checkout \
  --data-dir /benchmark/opencode-state \
  --artifacts /path/to/private-opencode-attempt \
  --isolation-wrapper "$ISOLATION_WRAPPER" \
  --isolation-wrapper-sha256 "$ISOLATION_WRAPPER_SHA256"
```

Run Veasel and OpenCode as separate attempts from reset workspaces. Do not run
them concurrently: they share the same local model and host resource budget.
The reports pin task/model/settings, but a comparison is valid only after both
outcomes are externally scored against the same oracle.

## Configured Muse Responses case

`cases/website-173-muse-spark-v0795/case.json` pins the same website issue,
base commit, prompt hash, Muse Spark 1.3 Contributor model, output ceiling,
permissions, and wall/resource limits for Veasel 0.79.5 and OpenCode 2.2.7.
The OpenCode adapter uses the documented OpenAI-compatible Responses runtime
and sends requests through `responses_proxy.py`, which in live mode accepts only
the pinned Meta host (the local fixture mode accepts loopback only), one
`/v1/responses` route, the exact model, a pinned OpenCode 2.2.7 request shape,
client-side function tools, and bounded output. Unknown top-level fields,
hosted tools, server-managed history, media, and unsupported input items are
rejected. Before each inference, the proxy sends the exact rendered input,
instructions, and function schemas to Meta's `/v1/responses/input_tokens`
endpoint, and stops if the returned context count exceeds 8,192. Meta documents
that the count includes the fully rendered request and is for context-window
fit, not billing estimation; the endpoint does not generate a response or
record generation usage. The proxy does not use its count as an estimated
charge. Hosted tools can produce cumulative input usage across multiple model
iterations, so this case rejects hosted tools and uses one client-side model
generation per request. [Meta token counting](https://dev.meta.ai/docs/token-counting),
[Responses usage](https://dev.meta.ai/docs/protocols/responses), and
[API billing](https://dev.meta.ai/help/billing/api-bill) document these boundaries.

Every inference attempt atomically reserves the worst-case charge for one
8,192-token context and 2,048 output tokens at the pinned uncached input and
output rates. The 84-attempt cap therefore reserves at most USD 0.10321920,
within this case's USD 0.11 ceiling and the operator-authorized USD 5 limit.
After a terminal streaming response, the proxy settles the reservation using
reported usage and still charges all input at the uncached rate for the cap.
If final usage is missing or ambiguous, it keeps the reservation and blocks
further generations. Each retry is a new reserved attempt. This bound assumes
one non-hosted model generation per POST and that Meta enforces the context and
`max_output_tokens` limits for that generation; hosted tools are rejected
because their cumulative input usage can exceed one context window. The local
OpenCode fixture proves routing and the count/usage protocol without contacting
Meta; it does not prove provider billing behavior or real-model success.

Both agents run from a new `--no-hardlinks` clone at
`<data-dir>/workspaces/veasel-real-task-*`; the user-provided baseline checkout
is left clean. The data directory and `workspaces` parent must be persistent,
owned by the current user, mode 0700, and outside `/tmp` and `/var/tmp`. Task
clones remain there after runner interruption or reboot so dirty candidate
changes can be recovered; they are never auto-deleted. The shell launcher accepts
only a direct task child of the explicitly supplied `VEASEL_REAL_TASK_PARENT`,
checks that parent ownership and permissions, rejects temporary roots, and
continues to bind only the task clone writable.
OpenCode's generated config points its shell tool at the SHA-256-pinned
`opencode-shell-sandbox.sh` wrapper, which starts Bubblewrap with a private
network/PID namespace and binds only the task clone writable. The proxy token
and upstream credential are not passed to that shell process. The runner also
requires a separately operator-reviewed outer wrapper whose path and SHA-256
are supplied at launch. Preflight fails closed unless Linux, the pinned shell
wrapper, executable Bubblewrap, a matching task clone, and the outer wrapper
are all wired. The wrapper digest identifies its bytes; its behavior still
requires operator review.

The private mode-0600 aggregate spend ledger enforces the user's USD 5 total
authorization across runs and concurrent runner processes. It imports USD
0.35444 as already consumed from the previous-session handoff, explicitly
marked approximate because its raw source was unavailable; this imported
amount is never refunded. Each remote run reserves its complete worst-case
ceiling before launch. A successful run releases the unused reserve only when
complete usage is available; interrupted runs and ambiguous usage keep their
full reservation across restarts. The ledger reports the imported uncertainty.

`test_opencode_responses_fixture.py` optionally drives the pinned OpenCode CLI
through the proxy into a deterministic local Responses fixture. It proves the
actual endpoint, model, streaming protocol, usage parsing, and credential
replacement without contacting Meta. This fixture is not real-model success.
The real run remains blocked until both the reviewed operator wrapper proves
that OpenCode shell tools cannot read the proxy token, reach the proxy directly,
or bypass it to contact Meta, and the input billing bound is validated. The
runner's current preflight fails these gates by design; do not remove them to
force a live run.

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
Endpoint strings are compared internally but omitted from preflight and attempt
reports. Endpoints with URL userinfo, query strings, or fragments fail
preflight; path components are also never copied into reports.

Paid configured-provider cases pin input/output rates, a maximum model request
count, and a case cost ceiling. The aggregate ledger is scoped to the existing
USD 5 authorization; `--approved-spend-usd` cannot exceed that total. Preflight
fails before a provider call if the ledger cannot reserve a full run.
The runner computes a conservative upper bound using the full context and output
limit on every allowed request and bills all input at the uncached rate. Pin the
Veasel version whose runtime enforces that request bound. This bounds declared
model-call exposure; it does not replace checking the provider's final invoice
or account-level controls. Attempt reports include a separate cost estimate
from reported token usage, and keep missing usage unknown.

The `website-173-muse-spark` case pins Meta's `muse-spark-1.3-contributor`, the
published Contributor rates, a USD 0.11 ceiling per attempt, 8,192 context /
2,048 output tokens, and 84 maximum HTTP attempts. This allows up to three
provider attempts per each of Veasel 0.79.2's 24 tool rounds, three edit-review
rounds, and one possible terminal tool-budget summary completion. Its
conservative worst-case estimate is USD 0.1032192. An earlier preflight
incorrectly omitted that summary completion and reported a USD 0.10 cap; the
attempts below are audited with the corrected USD 0.11 reserve. The runtime
version and binary hash are pinned because the request count follows these
bounded retry limits. For each run whose provider usage is unavailable, reserve
its full worst-case USD 0.10321920 cap in the aggregate ledger. The original case retains its
0.79.2 binary pin for replay. The separate
[`website-173-muse-spark-v0793`](cases/website-173-muse-spark-v0793/case.json)
case pins Veasel `0.79.3-next.0`, binary SHA-256
`f9055a2ca22d0ed0f5f670b0499664f87c765a4ce6376bbe77a1f68c3242080b`, and case
SHA-256 `619e50221c8bbfb25a3680c458f4352578be536c87d6d3a7862f9638d5c04517`.
Attempt reports include the exact case SHA-256, so results remain attributable
to the immutable case revision.

```sh
python3 benchmarks/real-task/run.py preflight \
  --case benchmarks/real-task/cases/website-173-muse-spark-v0793/case.json \
  --workspace /path/to/disposable/website-checkout \
  --data-dir /benchmark/state \
  --approved-spend-usd 5
```

Create the isolated `model-settings.json` from the saved profile without
printing or copying the credential into command arguments, and switch only that
isolated profile to the exact case model before preflight. The profile readiness
check verifies that a credential exists but does not test it against Meta. The
corpus still has no successful externally verified website#173 attempt; a
completed turn remains unscored until the independent oracle passes.
