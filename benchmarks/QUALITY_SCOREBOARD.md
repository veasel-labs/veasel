# Product quality scoreboard

Updated 2026-11-11. This file records evidence, not marketing claims. The live
mission and acceptance gates are tracked in [veasel#549](https://github.com/veasel-labs/veasel/issues/549).

## Real coding-task acceptance

| Task | Attempts | Success | Current finding |
|---|---:|---:|---|
| [website#173](https://github.com/veasel-labs/website/issues/173), mobile documentation navigation | 17 attempts (1 resource-aborted) | 0 | Four additional same-model runs used one newly authored prompt (hash differs from the historical prompt). They repeated listings, read unrelated source, made an unrelated malformed Astro edit (caught by external `npm run check`), or meandered through release files for 8m30s with 58,129 reported input tokens and no edit. Focused inspection and the post-edit verification gate did not yield a correct task outcome; the latest run never reached verification. See the [diagnostic series](reports/real-task-attempts/veasel-qwen3-8b-website-173-followthrough-diagnostics-2026-11-11.json). |
| Synthetic single-file docs sidebar label calibration | 6 attempts | 2 | Two externally verified exact one-line edits followed the new exact-text replacement path (140 s and 100 s; 10,334/117 and 10,326/118 input/output tokens). A temporary wider post-read tool set made an off-target placeholder edit and falsely claimed success; both successful runs used the narrower post-read edit-only phase. Earlier attempts exposed a missed intent classification, destructive full-file editing, and full-file proposal timeouts. One exact-prompt run succeeded; three exact-prompt attempts produced one success. This calibration does not count as success on website#173. See the [attempt report](reports/calibration-docs-sidebar-label-qwen3-8b-2026-11-11.json). |

The attempts use local Qwen models. One Veasel packaged TUI run and one OpenCode
2.2.5 TUI run now form a matched diagnostic pair: same task, exact prompt hash,
base commit, model digest, context/output budgets, edit/bash permissions, disabled
MCP, and 180 s wall limit. Both produced zero edits. Veasel reported its provider
timeout; OpenCode was externally interrupted at the wall limit. One pair is not
enough to claim comparative quality or speed. The [pair report](reports/real-task-comparison-website-173-2026-11-11.json)
and [snapshot](reports/real-task-website-173-2026-11-11.json) record the evidence. A Qwen3:14b attempt in a filesystem-isolated Veasel headless sandbox was stopped after 56 s because it consumed about 10 GiB RSS and drove host memory pressure; the checkout stayed clean and this is recorded as an unscored resource abort in [its report](reports/real-task-attempts/veasel-qwen3-14b-website-173-2026-11-11.json).

## Current acceptance status

| Gate | Status | Evidence / remaining work |
|---|---|---|
| Real task success | **Open** | The synthetic single-file calibration has two externally verified successes through exact-text replacement. The actual website#173 issue remains at 0 successes after 17 attempts. The latest two runs produced no edit; one earlier edit was incorrect and failed Astro check. Broaden the task corpus only after fixing model capability/tool selection and getting post-edit verification to run on an actual edit. |
| Same-model competitive benchmark | **Open** | Need identical task, model digest, permissions, context/output budgets, repository, and oracle. |
| Headless approval honesty | **Fix in progress** | Regression now hides denied effect tools and rejects false completion claims for explicit code changes in non-interactive `ask` mode. |
| Packaged first-use and TUI journeys | **Partial** | Official `0.69.13-next.0` Linux binaries passed a clean-profile mock-provider walk through `/connect`, model discovery, persisted session/reply, approved edit, restart, and SIGKILL recovery at 32×12, 80×30, and 120×40. One launch-to-home sample was 102 ms. This is deterministic UX evidence, not real-model success; see the [packaged smoke report](reports/tui-package-smoke-v0.69.13-linux-2026-11-11.json). Real-provider task completion and physical-device/macOS/Windows acceptance remain open. |
| Homebrew/AUR parity | **Versions aligned; mirror merged** | Homebrew main references `0.69.13-next.0` (commit `56eb3bf`); macOS install/upgrade/uninstall CI passed. The AUR publisher verified, built, installed, and published `0.69.13.next.0-1`; live AUR RPC and merged GitHub mirror PR [#26](https://github.com/veasel-labs/aur-package/pull/26) agree on version and release checksum. |
| Website release authenticity | **Current snapshot matches** | Website `verified-release.json` references `v0.69.13-next.0` and source commit `1334e48ca09dd06af9acc628c978f19ad2541c75`. |

## Measurement limits

The snapshot does not include CPU, peak memory, or complete timing for every
attempt. The context-window diagnostic took 144 seconds versus 274 seconds in
the immediately prior guarded run; this is one diagnostic pair and is not a
general speed claim. It sampled 5.9 GiB model RSS and 4.1 GiB host-available
memory, not peak values. The three latest website#173 diagnostic runs took 156,
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
report.

## Model capability probe

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
