# Product quality scoreboard

Updated 2026-11-13. This file records evidence, not marketing claims. The live
mission and acceptance gates are tracked in [veasel#549](https://github.com/veasel-labs/veasel/issues/549).

## Real coding-task acceptance

| Task | Attempts | Success | Current finding |
|---|---:|---:|---|
| [website#173](https://github.com/veasel-labs/website/issues/173), mobile docs navigation | 30 earlier attempts (4 resource aborts; 3 timeouts) + 2 unscored Muse provider errors + 1 matched Muse pair (2 attempts) | 0 | Earlier runs failed through irrelevant search, off-task edits, and timeouts. The matched Veasel 0.74.0/OpenCode 2.2.7 pair both failed the independent oracle (Veasel inert scaffold; OpenCode timeout). A Muse attempt on 0.70.0 ended HTTP 400 before edit; the PR #653 candidate made 3 tool calls then got HTTP 400 after compaction (8.743 s). Both provider errors lack usage/resource samples and are unscored. See [paired report](reports/real-task-comparison-website-173-muse-2026-11-12.json), [first error](reports/real-task-attempt-website-173-muse-provider-error-2026-11-12.json), [post-compaction error](reports/real-task-attempt-website-173-muse-compaction-400-2026-11-12.json). PR #653 adds bounded post-edit acceptance and compaction guards; real-model mitigation remains unverified. |
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
| Same-model competitive benchmark | **Preliminary pairs; open** | The Qwen3:8b website#173 pair yielded 0/1 correct outcomes for both agents. The Muse Spark 1.3 Contributor website#173 pair also yielded 0/1 each; resource samples were missed, and permissions differ in sandbox implementation. A separate Muse slugify fixture passed 1/1 for each, but OpenCode's aggregate usage was not captured and the task is synthetic. More pinned real-repository trials with complete traces, usage, timing, and resource measurements are required; no relative quality, speed, or cost claim is supported. See the [Qwen pair](reports/real-task-comparison-website-173-head-4198446-2026-11-11.json), [Muse website pair](reports/real-task-comparison-website-173-muse-2026-11-12.json), and [Muse fixture pair](reports/real-task-comparison-slugify-muse-2026-11-12.json). |
| Cross-provider child execution | **Deterministic concurrency verified; real-provider coding open** | Merged PR #656 uses HTTP test adapters to verify actual provider routing for two child calls, overlapping execution, independent completion, and provider/model-attributed results in one parent conversation. No real external provider call or coding task was part of this test. |
| Agent token/cost boundaries | **Token ceilings merged; dollar cap open** | Merged PR #651 adds durable process-wide parent/child token reservations and reports only adapter-provided costs. It deliberately does not claim or enforce a hard-dollar cap; safe per-provider price bounds and spend enforcement remain open. |
| Headless approval honesty | **Implemented; scripted coverage** | Merged PR #609 hides denied effect tools and rejects false completion claims for explicit code changes in non-interactive `ask` mode. Deterministic regression coverage passed; real-model task success remains unproven. |
| Packaged first-use and TUI journeys | **Linux .78.0 deterministic workflow passed; other packaged platforms open** | Official Linux `v0.78.0-next.0` binaries passed clean-profile `/connect`, persisted reply, approved edit, delegation, independent child cancellation, graceful restart, SIGKILL recovery to `uncertain`, and six sizes (32×12 through 120×40). Archive and internal binary hashes match official manifests. The report explicitly measures launch-to-home only (median 145.78 ms, 3 samples); full workflow timing and CPU/peak-memory were not captured. This is deterministic mock-provider UX/orchestration evidence, not real-model coding success. macOS/Windows release-asset journeys remain open. See [the report](reports/tui-package-smoke-v0.78.0-linux-2026-11-13.json) and [PR #659](https://github.com/veasel-labs/veasel/pull/659).
| Homebrew/AUR parity and install lifecycle | **v0.78.0 published to Homebrew and AUR; package checks passed** | Latest release is [`v0.78.0-next.0`](https://github.com/veasel-labs/veasel/releases/tag/v0.78.0-next.0). Homebrew #39 and AUR mirror #39 merged; Homebrew cask and Arch package CI passed. AUR publisher [43352218253](https://github.com/veasel-labs/aur-package/actions/runs/43352218253) built/installed the package and published to AUR. The public package page shows `0.78.0.next.0-1`; the AUR RPC v5 endpoint remained cached at `.77.0` at the last check, so API propagation still needs confirmation. |
| Website release authenticity | **v0.78.0 deployed and verified** | Website PR [#200](https://github.com/veasel-labs/website/pull/200) merged the release metadata tied to source `9a2cf29645e5d7f389d08e64c315c561123d0ffb`. Main CI [43351897104](https://github.com/veasel-labs/website/actions/runs/43351897104) and production deploy [43351897010](https://github.com/veasel-labs/website/actions/runs/43351897010) passed. The public downloads page lists `v0.78.0-next.0` and the official archive hashes. |

## Measurement limits

The versioned local real-task runner in [`real-task/README.md`](real-task/README.md)
now pins the website#173 prompt, base commit, local model digest, and token
budgets. It has Veasel and OpenCode launch adapters under the same case; its
preflight checks checkout cleanliness, exact model/runtime, provider config,
and minimum host resources. The launcher applies context/output limits and
classifies resource aborts separately from task failures. No matched pair has
been completed through the new runner, so this adds no scored attempt and does
not solve the current task-success gap.

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
