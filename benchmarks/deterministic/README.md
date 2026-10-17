# Deterministic fixture benchmarks

Scripted, offline, zero-cost fixtures that exercise Veasel's real headless
agent loop (backend, provider adapter, tool orchestration, edit application,
ATIF trace) against the repository's mock OpenAI-compatible provider
(`scripts/mock-provider.py`). The provider replies are fixed, so repeated
runs are directly comparable and regressions are attributable to the harness,
not to a model.

## Run

```sh
python3 benchmarks/deterministic/run.py --veasel /path/to/veasel \
    --report benchmarks/reports/deterministic-linux-x64-YYYY-MM-DD.json
```

Exit status is non-zero when any task fails. Tasks are scored by external
checks on the resulting workspace (for example, the applied file content),
never by the agent's own final message. Reports record wall time, ATIF
step/tool-call counts, provider-reported token usage, and the SHA-256 of the
binary under test.

## Fixtures

| Fixture | Prompt | External check |
| --- | --- | --- |
| `autonomous-workspace-edit` | `Autonomous workspace edit` | `src/main.v` contains the applied `greet` function |
| `greeting-reply` | `Say hello` | Run completes with the fixture reply |

## Same-model comparisons

```sh
python3 benchmarks/deterministic/run.py --agent opencode \
    --report benchmarks/reports/deterministic-opencode-linux-x64-YYYY-MM-DD.json
```

The OpenCode adapter runs the same externally-checked edit fixture through
OpenCode's own `write` tool against `scripted_provider.py`, a generic
scripted OpenAI-compatible endpoint that answers with whichever write/edit
tool the agent advertises. Two integration facts worth knowing:

- OpenCode resolves its project root from `$PWD`, not `getcwd(3)`; the
  adapter sets `PWD` explicitly or the fixture `opencode.json` is ignored
  and the run fails with `Model unavailable`.
- OpenCode may query `GET /v1/models`; the scripted provider implements it.

The Pi adapter (`--agent pi`) uses the same provider and check, configured
through an isolated `PI_CODING_AGENT_DIR` so user Pi state is never touched.

First local comparison (2026-10-17, scripted replies, cold CLI runs, same
external check — all passing):

| Agent | Wall time |
| --- | --- |
| Veasel | 264 ms |
| Pi 0.85.1 | 492 ms |
| OpenCode 2.0.27 | 4,588 ms |

This measures harness/startup orchestration only — scripted replies say
nothing about model quality, and no superiority claim is supported until
real same-model runs with an authorized budget record model, provider,
versions, limits and raw outcomes per `docs/benchmarking.md`. Codex and
mini-SWE-agent adapters remain follow-ups (Codex needs a Responses-API
scripted endpoint).
