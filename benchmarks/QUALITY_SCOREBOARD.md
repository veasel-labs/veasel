# Product quality scoreboard

Updated 2026-11-12. This file records evidence, not marketing claims. The live
mission and acceptance gates are tracked in [veasel#549](https://github.com/veasel-labs/veasel/issues/549).

## Real coding-task acceptance

| Task | Attempts | Success | Current finding |
|---|---:|---:|---|
| [website#173](https://github.com/veasel-labs/website/issues/173), mobile documentation navigation | 30 earlier attempts (4 resource-aborted; 3 timeouts) + 1 earlier unscored provider error + 1 matched Muse pair (2 attempts) | 0 | Earlier same-prompt runs repeated listings, read unrelated source, made off-task edits, or timed out. The 20-call PR #610 attempt exhausted 300 seconds in release-code exploration. The next build rejected an unrelated search, found the sidebar source, then made a placeholder replacement that matched zero occurrences and stopped after six calls/223 seconds. A recovery-build run was stopped before its first tool call when Qwen3:8b drove available RAM to 1.2 GiB and swap free space to 6 MiB; memory recovered after cancellation and unload. A completed PR #614 head run then searched the exact multiword phrase `docs sidebar navigation`, received no matches, and returned cleanly without reading or editing source (6.1 s, 10,049 prompt tokens, 145 output tokens). Two replays with the local search fallback were stopped by the RAM guard before a completed turn (13.2 s and 11.1 s) and are unscored. One run of the official 0.70.0 binary with the configured Muse provider made a rejected `workspace_search` call, then ended with HTTP 400 before any edit (4.815 s); provider body, usage and resource samples were unavailable, so it is separately recorded as unscored. The new paired Muse run used the official Veasel 0.74.0 artifact and OpenCode 2.2.7 against the same pinned website commit and prompt: Veasel stopped after an inert button scaffold (84.6 s); OpenCode made no edits before its 330-second timeout. Both failed the independent oracle; measured usage and the estimated/reported costs are in the [Muse website task report](reports/real-task-comparison-website-173-muse-2026-11-12.json). Resource samples were not captured, and one pair supports no speed or quality comparison. See the [Muse provider error report](reports/real-task-attempt-website-173-muse-provider-error-2026-11-12.json), [post-#614 search failure](reports/real-task-attempt-website-173-post-614-search-failure-2026-11-11.json) and [post-fallback resource aborts](reports/real-task-attempt-website-173-post-fallback-resource-abort-2026-11-11.json), [including the later replay](reports/real-task-attempt-website-173-post-fallback-resource-abort-retry-2026-11-11.json). PR #610 now allows one fresh read and corrected edit proposal after validation failure while retaining exact-match safety; real-model validation remains open. See the [diagnostic series](reports/real-task-attempts/veasel-qwen3-8b-website-173-followthrough-diagnostics-2026-11-11.json), [matched baseline pair](reports/real-task-comparison-website-173-head-4198446-2026-11-11.json), [first search-gate attempt](reports/real-task-attempt-website-173-search-gate-2026-11-11.json), [off-target edit attempt](reports/real-task-attempt-website-173-search-gate-v2-2026-11-11.json), [zero-call lexical-gate attempt](reports/real-task-attempt-website-173-search-relevance-2026-11-11.json), [action-first attempt](reports/real-task-attempt-website-173-action-first-2026-11-11.json), [relevant-gate attempt](reports/real-task-attempt-website-173-relevant-gate-2026-11-11.json), and [resource-aborted recovery run](reports/real-task-attempt-website-173-recovery-resource-abort-2026-11-11.json). |
| Synthetic single-file docs sidebar label calibration | 6 attempts | 2 | Two externally verified exact one-line edits followed the new exact-text replacement path (140 s and 100 s; 10,334/117 and 10,326/118 input/output tokens). A temporary wider post-read tool set made an off-target placeholder edit and falsely claimed success; both successful runs used the narrower post-read edit-only phase. Earlier attempts exposed a missed intent classification, destructive full-file editing, and full-file proposal timeouts. One exact-prompt run succeeded; three exact-prompt attempts produced one success. This calibration does not count as success on website#173. See the [attempt report](reports/calibration-docs-sidebar-label-qwen3-8b-2026-11-11.json). |
| Paired synthetic slugify fixture (Muse Spark 1.3 Contributor) | 1 attempt per agent | 1/1 each | Veasel 0.71.1 and OpenCode 2.2.7 both changed only `slug.py` and passed the same four independent Python tests. Veasel reported 58,879 input / 5,178 output tokens. OpenCode's captured JSON was truncated; only a lower bound of 7,307 input / 249 output tokens is available. This is a small fixture, not a real repository issue or comparative speed/cost claim. See the [paired report](reports/real-task-comparison-slugify-muse-2026-11-12.json). |

One paired synthetic coding fixture now has externally verified success on
both Veasel and OpenCode; it does not change website#173's 0/30 score or
establish general quality. A local candidate from source `6285cf1` was rebuilt with installed V 0.5.2
`b0ceb9b` (binary SHA-256
`2481356332355c968c517b759a1feec1a9096077f3f1f19f8f21bcacb641a25c`). Recent
host samples showed 4.1–5.2 GiB available RAM, below the 5.75 GiB local-model
startup reserve; the local Ollama endpoint was inactive at preflight. A later
single external Muse-provider attempt did run, but failed before editing and is
unscored as described above. See the [guarded 2026-11-12 preflight](reports/real-task-preflight-website-173-2026-11-12.json).

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
| Agent token/cost boundaries | **Token ceilings in review; dollar cap open** | PR #651 adds durable process-wide parent/child token reservations and reports only adapter-provided costs. Its Meta fixture regression is fixed and required CI is running. It deliberately does not claim or enforce a hard-dollar cap; safe per-provider price bounds and spend enforcement remain open. |
| Headless approval honesty | **Implemented; scripted coverage** | Merged PR #609 hides denied effect tools and rejects false completion claims for explicit code changes in non-interactive `ask` mode. Deterministic regression coverage passed; real-model task success remains unproven. |
| Packaged first-use and TUI journeys | **Linux .77.0 passed; macOS/Windows open** | Official Linux `.77.0` binaries passed clean-profile `/connect`, model discovery, persisted prompt/reply, approved edit with verified contents, delegation/result inspection, independent child cancellation while a sibling completed, graceful restart, SIGKILL recovery to `uncertain`, and all six sizes (32×12 through 120×40). Binary hashes match `build.json`. This is deterministic mock-provider UX/orchestration evidence, not real-model coding success. macOS/Windows release-asset journeys remain open. See [the .77.0 replay](reports/tui-package-smoke-v0.77.0-linux-2026-11-13.json).
| Homebrew/AUR parity and install lifecycle | **GitHub metadata merged; AUR publication running** | Latest release is [`v0.77.0-next.0`](https://github.com/veasel-labs/veasel/releases/tag/v0.77.0-next.0). Homebrew/AUR metadata PRs #37 merged and post-merge package CI passed. Homebrew CI covers install, upgrade, and uninstall. AUR PR CI validates the Arch package; publisher run [43338456574](https://github.com/veasel-labs/aur-package/actions/runs/43338456574) must complete before claiming live AUR parity. macOS/Arch install acceptance beyond CI artifacts and package update lifecycle remain open.
| Website release authenticity | **0.70.0 deployed and verified; 0.71.1 sync unverified** | Website PR [#195](https://github.com/veasel-labs/website/pull/195) merged the verified `v0.70.0-next.0` manifest and source commit `e696634275784e80c1010a5934772d23648a706a`. Main CI [43154737398](https://github.com/veasel-labs/website/actions/runs/43154737398) and production deploy [43154737393](https://github.com/veasel-labs/website/actions/runs/43154737393) passed. The `v0.71.1-next.0` live-site manifest and downloads remain to be verified. |

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
