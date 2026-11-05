# Veasel Code — competitive gap analysis and product quality gates

**Snapshot:** 2026-11-04. **Scope:** [veasel](https://github.com/veasel-labs/veasel), [website](https://github.com/veasel-labs/website), [Homebrew](https://github.com/veasel-labs/homebrew-tap), [AUR](https://github.com/veasel-labs/aur-package), and [.github](https://github.com/veasel-labs/.github).

> Product owner feedback: Veasel is not currently usable as a daily driver. This is the leading product defect. We must not optimize for a large feature count or marketing claims at the expense of completing useful coding tasks.

## Competitors and what they set as a minimum bar

This is a capability audit from public project documentation, **not** a measured head-to-head benchmark.

| Competitor | Public capability / UX baseline | Veasel must demonstrate |
|---|---|---|
| [OpenCode](https://dev.opencode.ai/v2/docs/cli/tui/) | Run directly in a project and type a prompt; `@` files, slash commands, sessions, prompt steering, queueing, undo/redo, shell mode, editor, model/agent switching, searchable palette. [Plugin documentation](https://opencode.ai/v2/docs/build/plugins/cli/) exposes UI extension points. | First keystroke works; no eaten characters; parity for critical commands; tested prompt/session lifecycle; predictable plugin behavior. |
| [Codex CLI](https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan) | Agent view, multi-agent workflows, worktrees, usage and good terminal output readability; cross-surface CLI/IDE/web. | Correct worktree isolation, actual subagent outcomes, inspectable usage, durable session recovery, readable events and reviews. |
| [Claude Code](https://code.claude.com/docs/en/overview) | Coding agent workflow integrated with tools, repo edits and terminal execution. | Reviewable safe effects, tool discipline, accurate streamed progress and recoverability without hidden retries. |
| [Pi](https://pi.dev/) | Minimal core with extensive extensions, provider switching, session modes, skills, configurable UI and tool lifecycle interception. | Prefer composable stable extension interfaces over a growing untyped menu of hardcoded actions. |
| [Aider](https://aider.chat/docs/repomap.html) | Symbol-aware, ranked repository map; [automatic lint/test](https://aider.chat/docs/usage/lint-test.html); git-centric edits. | Benchmark semantic retrieval, verify edits against tests, and explain context selection. |
| [Goose](https://github.com/aaif-goose/goose) | Native desktop + CLI + API, multiple providers, MCP-based extensions and cross-platform distribution. | Reliable native packaging and cross-platform integrations; prioritize real install→connect→solve workflows. |

Do not claim parity or superiority because a menu item is present. Capability is `implemented + operationally verified + discoverable + safe`.

## Verified gaps in Veasel's source / CI

- **Broken provider filter typing:** focused input swallows printable `j`, `k`, `g` and number keys (code inspection). Remediation proposed in veasel#546.
- **Misleading home copy:** splash says “Ask anything to begin” although the home UI is a navigator and a session/model are required first. Proposed in veasel#546.
- **OpenTUI dependency compatibility:** update from 0.6.8 to 0.7.0 in veasel#544 fails four visual tests: label truncation for `build` and `FAILED`, plus missing `v word-diff`. Remediation proposed in veasel#547; validate by live CI rather than assertions alone.
- **Limited comparable task results:** the available Harbor installed-agent *adapter smoke* is not a Harbor Index submission or verified public task-completion benchmark.
- **Startup benchmarks do not prove agent performance:** the documented `veasel --version` p50 (~2.94 ms) refers to a former release (v0.58.0-next.0); it is not coding-task completion or current TUI readiness.
- **Endpoint presets are not provider implementations:** a curated list of 210 presets is distinct from native implementation of four API protocol families.
- **Remaining functional roadmap:** typed provider/tool interfaces, broader subagent orchestration with isolation, stronger semantic search, PTY real-world workflows, reproducible cross-platform interactive latency benchmarks.
- **Product website:** quickstart needs to track real keystrokes and verified shipping functionality; docs PR website#170 is an initial correction, not a visual redesign.

## Non-negotiable release gates

### G0 — install, connect, first prompt (P0)

From a clean profile on Linux/macOS/Windows, launch a **real packaged binary**, see an actionable next step, connect a provider without entering an unnecessary base URL, select a model, create/open a project session and submit a prompt. Verify a provider request is actually sent. Test Kimi, Gemini, Jina and numeric-prefix provider filtering. Use disposable credentials; do not log keys.

### G1 — correct agent work (P0)

On pinned *real* fixtures, agent must read and interpret a repo, propose a multi-file edit, show an accurate diff, require the appropriate policy decision, write only after authorization, run tests, summarize changed files and pass a defined correctness oracle. At least one intentionally failing, ambiguous, multi-step and long-session case. No fixture-only demos as proof.

### G2 — safety and durability (P0)

Prove fail-closed sandbox on supported platforms and missing backend; no secret leakage in logs; cancellation and interrupted sessions leave inspectable, accurate states; no duplicate applied edit, tool call or shell effect upon recovery. Negative tests matter as much as success tests.

### G3 — terminal UX (P0)

Golden journey coverage in `32×12`, `40×16`, `80×24`, `80×30`, `100×35`, `120×40` with accessible contrast, screen resizing, keyboard/mouse, fast typing, backspace, multiline, autocomplete, long diff, modal filtering, close/reopen, streaming scroll and selected labels never clipped. Pair snapshot tests with PTY and ConPTY end-to-end evidence.

### G4 — performance and efficiency (P1)

On matched hardware, budget, prompts, model and pinned test commit, measure **cold and warm start**, ready-to-type, p50/p95 first output, task wall time, tool counts, tokens, retries, provider-reported cache, peak RSS/CPU and task correctness. Save raw data, environment versions, command and cost. Never advertise fastest or best without independent, statistically credible task-level evidence.

### G5 — site and distribution (P1)

Astro build/typecheck/format/link/accessibility/responsive and actual release archive downloads pass; installation works through Homebrew on supported macOS and AUR on supported Arch Linux. Website screenshots and claims must reflect the shipped binary and cite verifiable data. Release only after main CI green **and** product acceptance.

## Execution order

1. **Repair daily-driver P0s** and keep CI green. Avoid modifying main without PR checks.
2. **Instrument and run complete journeys** (no real API key in CI).
3. **Fix highest-frequency friction** from journey logs and hands-on dogfooding; repeat until no P0 blocker remains.
4. **Raise correctness and context quality**, using controlled real coding-task comparisons.
5. **Polish design and site**, with screenshots, responsive/a11y audits, and cross-platform installer verification.
6. **Publish release** only when evidence justifies it.

## Evidence discipline

Keep an explicit `verified`, `hypothesis`, or `not tested` status for every claim. CI green is necessary but not sufficient for usability. Do not weaken assertions to pass dependency upgrades. Do not treat a sample fixture, one fast startup command or a marketing comparison as proof that Veasel beats Codex, Claude Code, OpenCode, Pi, Goose or Aider.
