# Product quality scoreboard

Updated 2026-11-13. This file records evidence, not marketing claims. The live
mission and acceptance gates are tracked in [veasel#549](https://github.com/veasel-labs/veasel/issues/549).

## Real coding-task acceptance

| Task | Attempts | Success | Current finding |
|---|---:|---:|---|
| [website#173](https://github.com/veasel-labs/website/issues/173), mobile docs navigation | 30 earlier attempts (4 resource aborts; 3 timeouts) + 2 unscored Muse provider errors + 1 matched Muse pair (2 attempts) + 3 Muse runs on main + 3 Muse Spark case runs + 2 v0.79.3 runs | 0 | Earlier runs failed through irrelevant search, off-task edits, and timeouts. The matched Veasel 0.74.0/OpenCode 2.2.7 pair both failed the independent oracle (Veasel inert scaffold; OpenCode timeout). A Muse attempt on 0.70.0 ended HTTP 400 before edit; the PR #653 candidate made 3 tool calls then got HTTP 400 after compaction (8.743 s). The first 2026-11-13 main run made six tool calls, then an ambiguous exact-text edit was rejected; recovery began but the operation failed at 60.03 s. A second main run searched four times, read one file, then proposed an edit against the literal path `placeholder`; the guarded workspace remained unchanged and the operation failed at 83 s. The third run used the read-before-edit guard, made two searches and two reads, then the turn failed before proposing an edit (44.3 s, 48.1 MB sampled peak process-tree RSS, 300 ms sampled CPU); its workspace remained clean. Three new isolated Muse Spark 1.3 Contributor attempts used the same pinned prompt/base/model: attempt A stopped on an incomplete Responses API stream after 28.0 s (five read/search calls, no edit, usage unavailable); attempt B completed in 80.0 s but changed only `DocsLayout.astro`, omitted required progressive enhancement and regression tests, and failed the independent oracle (75,013 input / 6,551 output tokens, estimated USD 0.008175, 31.7 MB sampled RSS, 230 ms sampled CPU); attempt C was resource-aborted at 45.0 s when host available memory fell to 4.34 GiB, so it is unscored and unchanged. A later runtime review found the original preflight omitted one possible terminal tool-budget summary completion (84 rather than 81 maximum HTTP attempts; USD 0.1032192 rather than USD 0.0995328). The case now uses a USD 0.11 ceiling; attempt A/C are conservatively reserved at USD 0.11 each because provider usage is unknown. Attempt B reports USD 0.00817538 from provider token usage. The incomplete-stream retry fix is covered deterministically, but attempt B's successful turn did not meet the task. Two further isolated runs used Veasel Code v0.79.3-next.0 (binary SHA-256 `f9055a2ca22d0ed0f5f670b0499664f87c765a4ce6376bbe77a1f68c3242080b`), identical website base `184c7d86911d4a760ec89c6ddc9097682e65da44` and prompt SHA-256 `5e2a8cede2b2f2736cfcda848294b1f488e1fdf43961bc4efa565282b0ea918e`. Run 1 exited successfully after 43.014 s (31,275 input / 4,982 output tokens; estimated USD 0.00403531); run 2 exited successfully after 111.020 s (344,796 input / 10,285 output tokens; estimated USD 0.01220330). Both failed the independent task oracle: they replaced the existing layout, removed search, omitted the required Browse sections and aria controls, and added no tests. The first run had 14 trace steps, applied a proposed file update, received repeated verification failures, and ended with the agent reporting the task incomplete even though the CLI exited 0. The second had 33 trace steps; after verification failed, it made no corrective edit despite explicit retry feedback and ended with acceptance unconfirmed. The respective sampled process-tree RSS maxima were 29,298,688 and 31,031,296 bytes; sampled CPU maxima were 140 and 440 ms. These are sampled measurements, not guaranteed peaks. A separate startup attempt failed before any provider call because the sandbox lacked its CA mount; it is unscored, with no reported usage, and conservatively reserved at up to the USD 0.11 case ceiling. No OpenCode same-model run was performed. Verified website#173 score remains 0. Sanitized attempt metadata was inspected locally; raw traces/logs and source output remain private. See [prior paired report](reports/real-task-comparison-website-173-muse-2026-11-12.json), [attempt A](reports/real-task-attempt-website-173-muse-spark-2026-11-13-a.json), [attempt B](reports/real-task-attempt-website-173-muse-spark-2026-11-13-b.json), and [attempt C](reports/real-task-attempt-website-173-muse-spark-2026-11-13-c.json). |
| Synthetic single-file docs sidebar label calibration | 6 attempts | 2 | Two externally verified exact one-line edits followed the new exact-text replacement path (140 s and 100 s; 10,334/117 and 10,326/118 input/output tokens). A temporary wider post-read tool set made an off-target placeholder edit and falsely claimed success; both successful runs used the narrower post-read edit-only phase. Earlier attempts exposed a missed intent classification, destructive full-file editing, and full-file proposal timeouts. One exact-prompt run succeeded; three exact-prompt attempts produced one success. This calibration does not count as success on website#173. See the [attempt report](reports/calibration-docs-sidebar-label-qwen3-8b-2026-11-11.json). |
| Paired synthetic slugify fixture (Muse Spark 1.3 Contributor) | 1 attempt per agent | 1/1 each | Veasel 0.71.1 and OpenCode 2.2.7 both changed only `slug.py` and passed the same four independent Python tests. Veasel reported 58,879 input / 5,178 output tokens. OpenCode's captured JSON was truncated; only a lower bound of 7,307 input / 249 output tokens is available. This is a small fixture, not a real repository issue or comparative speed/cost claim. See the [paired report](reports/real-task-comparison-slugify-muse-2026-11-12.json). |

One paired synthetic coding fixture now has externally verified success on
both Veasel and OpenCode; it does not change website#173's 0/30 score or
establish general quality. A local candidate from source `6285cf1` was rebuilt with installed V 0.5.2
`b0ceb9b` (binary SHA-256
`2481356332355c968c517b759a1feec1a9096077f3f1f19f8f21bcacb641a25c`). Recent
host samples showed 4.1–5.2 GiB available RAM, below the 5.75 GiB local-model
startup reserve; the local Ollama endpoint was inactive at preflight. Two Muse provider errors failed before a verified edit and remain unscored. See the [guarded 2026-11-12 preflight](reports/real-task-preflight-website-173-2026-11-12.json).

The attempts use local Qwen models. The official Veasel 0.69.13 packaged TUI run timed out after 180 seconds before its first tool call and displayed only “The assistant turn failed.” OpenCode 2.2.5 was externally stopped at the same wall limit with no assistant output or tool call. They form one matched diagnostic pair: same task, exact prompt hash,
base commit, model digest, context/output budgets, edit/bash permissions, disabled
MCP, and 180 s wall limit. Both produced zero edits. Veasel’s saved source commit predates the more specific timeout message merged in PR #609 commit `815c57d`; that UX change does not solve the underlying model timeout. One pair is not
enough to claim comparative quality or speed. The [pair report](reports/real-task-comparison-website-173-2026-11-11.json)
and [snapshot](reports/real-task-website-173-2026-11-11.json) record the evidence. A Qwen3:14b attempt in a filesystem-isolated Veasel headless sandbox was stopped after 56 s because it consumed about 10 GiB RSS and drove host memory pressure; the checkout stayed clean and this is recorded as an unscored resource abort in [its report](reports/real-task-attempts/veasel-qwen3-14b-website-173-2026-11-11.json).

The only installed larger model is Qwen3:14b (Q4_K_M, 14.8B parameters). A rerun
requires at least 12 GiB currently available RAM and 2 GiB free swap before
launch, providing margin over the previously observed 10 GiB model RSS. The
latest host snapshot had 8 GiB available RAM and only 102 MiB free swap, so no
14B attempt was started. This is a resource constraint, not evidence that the
larger model cannot code.

## Current acceptance status

| Gate | Status | Evidence / remaining work |
|---|---|---|
| Real task success | **Open** | The synthetic sidebar calibration and paired slugify fixture passed independent oracles, but neither counts as a success on a real repository issue. website#173 remains at 0 verified successes. The latest matched Muse pair also failed the external oracle for both agents; Veasel left a nonfunctional scaffold and OpenCode timed out before editing. Real-repository success is still unproven. |
| Same-model competitive benchmark | **Preliminary pairs; open** | The Qwen3:8b website#173 pair yielded 0/1 correct outcomes for both agents. The Muse Spark 1.3 Contributor website#173 matched pair also yielded 0/1 each. Three new Veasel-only runs now have reproducible resource and usage capture, but no live configured-Meta OpenCode attempt has passed preflight. The candidate OpenCode Responses adapter routes pinned OpenCode 2.2.7 through a local fixture and records usage. Its USD 0.10690560 per-case value is an estimate, not a guaranteed cap: provider framing/tokenization overhead is not bounded. Live use remains blocked until both the cost basis is validated and a reviewed wrapper prevents shell tools from reading the proxy key or reaching the proxy/provider directly. The completed Veasel turn still failed the oracle; no relative quality, speed, or cost claim is supported. See the [OpenCode local fixture report](real-task/reports/opencode-responses-fixture-v0.79.5-2026-11-13.json), [Qwen pair](reports/real-task-comparison-website-173-head-4198446-2026-11-11.json), [Muse website pair](reports/real-task-comparison-website-173-muse-2026-11-12.json), [new attempt A](reports/real-task-attempt-website-173-muse-spark-2026-11-13-a.json), [attempt B](reports/real-task-attempt-website-173-muse-spark-2026-11-13-b.json), [attempt C](reports/real-task-attempt-website-173-muse-spark-2026-11-13-c.json), and [Muse fixture pair](reports/real-task-comparison-slugify-muse-2026-11-12.json). |
| Cross-provider child execution | **Deterministic concurrency verified; real-provider coding open** | Merged PR #656 uses HTTP test adapters to verify actual provider routing for two child calls, overlapping execution, independent completion, and provider/model-attributed results in one parent conversation. No real external provider call or coding task was part of this test. |
| Agent token/cost boundaries | **Per-case cost preflight added; provider billing controls open** | Configured-provider cases pin rates, context/output limits, request/retry ceilings, binary hash, and per-attempt maximum cost. Preflight requires an explicit operator-approved total budget and rejects a worst-case bound above it. Attempt reports estimate cost from provider-reported usage and retain unavailable values as unknown. This bounds model-call exposure for the pinned runtime; it does not replace provider account controls or invoice verification. |
| Headless approval honesty | **Implemented; scripted coverage** | Merged PR #609 hides denied effect tools and rejects false completion claims for explicit code changes in non-interactive `ask` mode. Deterministic regression coverage passed; real-model task success remains unproven. |
| Packaged first-use and TUI journeys | **Linux .78.0 deterministic workflow passed; other packaged platforms open** | Official Linux `v0.78.0-next.0` binaries passed clean-profile `/connect`, persisted reply, approved edit, delegation, independent child cancellation, graceful restart, SIGKILL recovery to `uncertain`, and six sizes (32×12 through 120×40). Archive and internal binary hashes match official manifests. The report explicitly measures launch-to-home only (median 145.78 ms, 3 samples); full workflow timing and CPU/peak-memory were not captured. This is deterministic mock-provider UX/orchestration evidence, not real-model coding success. macOS/Windows release-asset journeys remain open. See [the report](reports/tui-package-smoke-v0.78.0-linux-2026-11-13.json) and [PR #659](https://github.com/veasel-labs/veasel/pull/659).
| Homebrew/AUR parity and install lifecycle | **v0.78.0 published to Homebrew and AUR; package checks passed** | Latest release is [`v0.78.0-next.0`](https://github.com/veasel-labs/veasel/releases/tag/v0.78.0-next.0). Homebrew #39 and AUR mirror #39 merged; Homebrew cask and Arch package CI passed. AUR publisher [43352218253](https://github.com/veasel-labs/aur-package/actions/runs/43352218253) built/installed the package and published to AUR. The public package page and AUR RPC v5 both report `0.78.0.next.0-1`. |
| Website release authenticity | **v0.78.0 deployed and verified** | Website PR [#200](https://github.com/veasel-labs/website/pull/200) merged the release metadata tied to source `9a2cf29645e5d7f389d08e64c315c561123d0ffb`. Main CI [43351897104](https://github.com/veasel-labs/website/actions/runs/43351897104) and production deploy [43351897010](https://github.com/veasel-labs/website/actions/runs/43351897010) passed. The public downloads page lists `v0.78.0-next.0` and the official archive hashes. |

## Measurement limits

The versioned local real-task runner in [`real-task/README.md`](real-task/README.md)
pins the website#173 prompt/base and local Qwen case, plus a configured Muse
Spark case with exact binary hash, provider target, token and cost ceilings.
The runner classifies resource aborts separately, checks profile readiness
without a provider probe, scrubs the saved key from disk before launch, and
passes it only to the backend process. Three Muse attempts ran through the
versioned case: one incomplete stream, one completed but partial edit, and one
resource abort. Two additional Muse runs on v0.79.3 completed the CLI process
but failed the independent website#173 oracle; a separate startup attempt failed
before contacting the provider because the sandbox lacked its CA mount. These
outcomes remain distinct from verified task success. A configured-Meta
OpenCode adapter and a same-case competitor pair remain open.

Merged PR #619 updates the benchmark runner to sample the agent process tree's
RSS and CPU time, host available RAM and swap, and device-wide GPU memory about
once per second. It reports sample maxima and sampling overhead, with explicit
scope notes; these are sampled maxima, not guaranteed true peaks. The current
model-attempt corpus has not yet been rerun through this enhanced collector,
and provider-reported token usage remains unavailable.

The older snapshot does not include CPU, peak memory, or complete timing for every
attempt. The context-window diagnostic took 144 seconds versus 274 seconds in
the immediately prior guarded run; this is one diagnostic pair and is not a
general speed claim. It sampled 5.9 GiB model RSS and 4.1 GiB host-available
memory, not peak values. The latest action-first attempt took 300 seconds,
recorded 20 context-compaction events, and sampled 5.9 GiB model RSS and 1.4 GiB
host-available memory; these are single samples, not peaks. The recovery-build
run was cancelled after 64 seconds at 1.2 GiB available RAM and 6 MiB free swap;
the model was unloaded and host availability recovered. The three latest
website#173 diagnostic runs took 156,
406, and 268 seconds; their raw tool traces are local only and no CPU or peak
memory samples were collected. A fourth run with a requested-verification gate
took 510 seconds and reported 58,129 input tokens, but made no edit; the gate
was not reached. These timings do not establish a speed claim.
The new calibration's two successful runs took 140 and
100 seconds; a temporary wider tool phase took 224 seconds and edited the wrong
string. This small sample does not support a general speed claim. The official-
release replay took roughly 351 seconds; the TUI provider request
failed at 180 seconds. Private ATIF traces remain outside version control;
sanitized tool-sequence summaries and outcomes are recorded in the attempt
report. The current-source pair recorded a 5.9 GiB Qwen runner RSS sample and 1.5–1.6 GiB host-available memory samples under concurrent workload; neither is a peak measurement. OpenCode produced no trace, and its exact local runner process was stopped after the client timeout.

## Model capability probe

On 2026-11-11, a read-only request through the full Veasel runtime using Qwen3:8b, Ollama 0.40.13, 4096 context, and a 1024-token output budget returned `empty_response` after 53 seconds, before any tool call. The CLI surfaced only “The assistant turn failed.” This is not a coding-task attempt and does not count as a success. A sanitized summary is in [the full-runtime probe report](reports/model-capability-veasel-runtime-qwen3-8b-2026-11-11.json). The API now maps `empty_response` to a specific, safe recovery message; the regression test passes under V 0.5.2.

With the same Qwen3:8b digest, a direct Ollama request with a 167-token prompt,
one required `edit_file` tool, and a 256-token output cap returned a structured
tool call in 31.38 seconds (29 output tokens). No tool was executed and no file
was changed. This confirms basic function-call output, not repository-aware
coding ability. A second minimal probe on the locally installed Ollama 0.40.13 compared
`reasoning_effort=none` with the field omitted. Both returned a tool call; the
explicit setting used 27 versus 130 completion tokens and took 24.66 versus
36.61 seconds in this single pair. This confirms the current server honors the
setting for this minimal request, but does not reproduce the long repository task
or explain its timeout. See the [original probe](reports/model-capability-qwen3-8b-tool-call-2026-11-11.json)
and [thinking-control comparison](reports/model-capability-qwen3-8b-thinking-control-2026-11-11.json).
