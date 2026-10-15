# Veasel Code documentation

Product docs for the V-native coding agent. Start at the repository
[README](../README.md) or [veasel.dev](https://www.veasel.dev/) for installs;
use this index when you need a specific contract or ledger.

## Start here

| Need | Document |
|------|----------|
| What is implemented vs open | [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) |
| Install & release policy | [RELEASES.md](RELEASES.md) |
| Provider catalog & setup | [PROVIDERS.md](PROVIDERS.md) |
| Shell approval & risk model | [SHELL_COMMANDS.md](SHELL_COMMANDS.md) |
| HTTP API (OpenAPI) | [openapi.yaml](openapi.yaml) |
| Local threat model | [security/threat-model.md](security/threat-model.md) |
| Agent Toolkit integration | [integrations/agent-toolkit.md](integrations/agent-toolkit.md) |

## Compatibility & research

| Topic | Document |
|-------|----------|
| Agent Plugins v1.0.0 ledger | [compatibility/agent-plugins.md](compatibility/agent-plugins.md) |
| OpenCode contract notes | [compatibility/opencode.md](compatibility/opencode.md) |
| Harbor adapter notes | [compatibility/harbor.md](compatibility/harbor.md) |
| Linux Bubblewrap shell sandbox pin | [compatibility/shell-bubblewrap-sandbox.md](compatibility/shell-bubblewrap-sandbox.md) |
| Competitive capability matrix | [COMPETITIVE_CAPABILITIES.md](COMPETITIVE_CAPABILITIES.md) |
| Competitive source study | [COMPETITIVE_SOURCE_STUDY.md](COMPETITIVE_SOURCE_STUDY.md) |
| Ecosystem research notes | [RESEARCH.md](RESEARCH.md) |
| V standard library reuse map | [VLIB_REUSE.md](VLIB_REUSE.md) |

## Builds & benchmarks

| Topic | Document |
|-------|----------|
| Compiler / production build profile | [V_BUILD_PROFILE.md](V_BUILD_PROFILE.md) |
| ATIF export & benchmark honesty | [benchmarking.md](benchmarking.md) |

## Reading order for contributors

1. [CONTRIBUTING.md](../CONTRIBUTING.md) and [AGENTS.md](../AGENTS.md)
2. [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md)
3. [openapi.yaml](openapi.yaml) for API surface
4. [security/threat-model.md](security/threat-model.md) before enabling tools
5. Compatibility ledgers before claiming external parity
