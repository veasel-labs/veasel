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

These fixtures are the deterministic foundation, not a competitive claim.
Extending the same fixtures, scoring and report schema to Codex, OpenCode,
Pi or mini-SWE-agent requires a per-agent adapter that points that agent at
the same scripted provider (or an equivalent scripted endpoint for its
protocol) and runs it in the same fixture workspace. Paid or real-model runs
require an authorized budget and must record model, provider, versions,
limits and raw outcomes per `docs/benchmarking.md`. No superiority claim is
supported by this harness until such a comparison has actually run.
