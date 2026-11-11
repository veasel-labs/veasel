# Product quality scoreboard

Updated 2026-11-11. This file records evidence, not marketing claims. The live
mission and acceptance gates are tracked in [veasel#549](https://github.com/veasel-labs/veasel/issues/549).

## Real coding-task acceptance

| Task | Attempts | Success | Current finding |
|---|---:|---:|---|
| [website#173](https://github.com/veasel-labs/website/issues/173), mobile documentation navigation | 7 diagnostic attempts | 0 | No run produced the expected patch. The latest release attempt timed out after one read-only file listing; the installed 0.67 binary returned unsupported completion claims without tools. |

The attempts use local Qwen models and one OpenCode run. They are not a controlled
Veasel-versus-OpenCode score: binary versions, execution permissions, and output
budgets differ. Do not infer comparative quality or speed from them. The
[snapshot report](reports/real-task-website-173-2026-11-11.json) records
fingerprints, outcomes, available token counts, and missing measurements.

## Current acceptance status

| Gate | Status | Evidence / remaining work |
|---|---|---|
| Real task success | **Open** | No externally verified edit yet; expand the small task corpus only after the harness yields repeatable runs. |
| Same-model competitive benchmark | **Open** | Need identical task, model digest, permissions, context/output budgets, repository, and oracle. |
| Headless approval honesty | **Fix in progress** | Regression now hides denied effect tools and rejects false completion claims for explicit code changes in non-interactive `ask` mode. |
| Packaged first-use and TUI journeys | **Open** | Existing CI coverage does not replace real hardware, PTY/ConPTY, accessibility, and complete workflow acceptance. |
| Homebrew/AUR parity | **In progress** | Homebrew main now references `0.69.13-next.0` (commit `56eb3bf`); its macOS install/upgrade/uninstall CI is running. Live AUR remains at `0.69.11.next.0-1`. |
| Website release authenticity | **Current snapshot matches** | Website `verified-release.json` references `v0.69.13-next.0` and source commit `1334e48ca09dd06af9acc628c978f19ad2541c75`. |

## Measurement limits

The snapshot does not include CPU, peak memory, or complete timing for every
attempt. The official-release replay's elapsed time is measured from the
command session at roughly 351 seconds; the other missing metrics remain
unknown. The historical Qwen3 and Qwen2.5 summaries are sanitized local
reports. Private ATIF traces remain outside version control because they may
contain workspace source and instructions.
