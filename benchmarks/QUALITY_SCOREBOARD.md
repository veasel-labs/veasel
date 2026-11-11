# Product quality scoreboard

Updated 2026-11-11. This file records evidence, not marketing claims. The live
mission and acceptance gates are tracked in [veasel#549](https://github.com/veasel-labs/veasel/issues/549).

## Real coding-task acceptance

| Task | Attempts | Success | Current finding |
|---|---:|---:|---|
| [website#173](https://github.com/veasel-labs/website/issues/173), mobile documentation navigation | 9 diagnostic attempts | 0 | No run produced the expected patch. The latest packaged Veasel TUI timed out before a tool call; one matched OpenCode TUI run was externally stopped at the same 180 s limit. Both worktrees stayed clean. |

The attempts use local Qwen models. One Veasel packaged TUI run and one OpenCode
2.2.5 TUI run now form a matched diagnostic pair: same task, exact prompt hash,
base commit, model digest, context/output budgets, edit/bash permissions, disabled
MCP, and 180 s wall limit. Both produced zero edits. Veasel reported its provider
timeout; OpenCode was externally interrupted at the wall limit. One pair is not
enough to claim comparative quality or speed. The [pair report](reports/real-task-comparison-website-173-2026-11-11.json)
and [snapshot](reports/real-task-website-173-2026-11-11.json) record the evidence.

## Current acceptance status

| Gate | Status | Evidence / remaining work |
|---|---|---|
| Real task success | **Open** | No externally verified edit yet; expand the small task corpus only after the harness yields repeatable runs. |
| Same-model competitive benchmark | **Open** | Need identical task, model digest, permissions, context/output budgets, repository, and oracle. |
| Headless approval honesty | **Fix in progress** | Regression now hides denied effect tools and rejects false completion claims for explicit code changes in non-interactive `ask` mode. |
| Packaged first-use and TUI journeys | **Partial** | Official `0.69.13-next.0` Linux binaries passed a clean-profile mock-provider walk through `/connect`, model discovery, persisted session/reply, approved edit, restart, and SIGKILL recovery at 32×12, 80×30, and 120×40. One launch-to-home sample was 102 ms. This is deterministic UX evidence, not real-model success; see the [packaged smoke report](reports/tui-package-smoke-v0.69.13-linux-2026-11-11.json). Real-provider task completion and physical-device/macOS/Windows acceptance remain open. |
| Homebrew/AUR parity | **Versions aligned; mirror merged** | Homebrew main references `0.69.13-next.0` (commit `56eb3bf`); macOS install/upgrade/uninstall CI passed. The AUR publisher verified, built, installed, and published `0.69.13.next.0-1`; live AUR RPC and merged GitHub mirror PR [#26](https://github.com/veasel-labs/aur-package/pull/26) agree on version and release checksum. |
| Website release authenticity | **Current snapshot matches** | Website `verified-release.json` references `v0.69.13-next.0` and source commit `1334e48ca09dd06af9acc628c978f19ad2541c75`. |

## Measurement limits

The snapshot does not include CPU, peak memory, or complete timing for every
attempt. The official-release replay's elapsed time is measured from the
command session at roughly 351 seconds; the other missing metrics remain
unknown. The historical Qwen3 and Qwen2.5 summaries are sanitized local
reports. The packaged TUI sample measured 5.9 GB model RSS and about 3.1
generated tokens/second on CPU. Other attempts still lack CPU, peak memory, and
complete timing. The official-release headless replay took roughly 351 seconds;
the TUI provider request failed at 180 seconds. Private ATIF traces remain
outside version control because they may contain workspace source and
instructions.

## Model capability probe

With the same Qwen3:8b digest, a direct Ollama request with a 167-token prompt,
one required `edit_file` tool, and a 256-token output cap returned a structured
tool call in 31.38 seconds (29 output tokens). No tool was executed and no file
was changed. This confirms basic function-call output, not repository-aware
coding ability. The contrast with the much larger TUI request suggests prompt
and orchestration load may contribute to the timeout; that remains an inference
from non-identical inputs, not an established root cause. See the
[sanitized capability probe](reports/model-capability-qwen3-8b-tool-call-2026-11-11.json).
