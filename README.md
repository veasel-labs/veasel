# Veasel Code

[![CI](https://github.com/veasel-labs/veasel/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/veasel-labs/veasel/actions/workflows/ci.yml)
[![Security](https://github.com/veasel-labs/veasel/actions/workflows/security.yml/badge.svg?branch=main)](https://github.com/veasel-labs/veasel/actions/workflows/security.yml)
[![Latest preview](https://img.shields.io/github/v/release/veasel-labs/veasel?include_prereleases&label=preview)](https://github.com/veasel-labs/veasel/releases)
[![Website](https://img.shields.io/badge/website-veasel.dev-3b6b54)](https://www.veasel.dev/)

Veasel Code is an open-source AI coding agent with a V-native runtime and a
server-first API. The project is being built in working vertical slices; see
[`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md) for the current
scope and status.

## Current status

The current vertical slice provides a V server with health/capability
endpoints, SQLite-backed sessions and chat history, a replayable event stream,
and an OpenTUI terminal client. When configured, sessions can chat through
OpenAI-compatible, Anthropic, or Gemini APIs. Repository tools, code changes,
and background execution are still in progress. Session chat can call bounded,
read-only workspace list/read/search tools using provider-native tool calling
for all three provider families. Requested workspace content is sent to the
configured model provider. The loop cannot write files or execute commands.
Local Agent Plugins can be discovered and their validated Skills enabled per
session; MCP declarations are metadata only and are not started. The product
reports only actual provider replies and does not simulate agent actions.

## Requirements

- The V compiler revision pinned in `.v-version` (CI installs the exact revision)
- SQLite development headers/library as required by V's `db.sqlite`
- Bun 1.3.14 or newer for the OpenTUI terminal client (not needed by the backend)

## Development

Start the V API in one terminal. For example, using Gemini:

```sh
export VEASEL_MODEL_PROVIDER=gemini
export VEASEL_MODEL=your-model-name
export GEMINI_API_KEY=your-api-key
v run . serve
```

Then launch the TUI from the repository in a second terminal:

```sh
v run . tui
```

The server defaults to `127.0.0.1:4097`. Set `VEASEL_DATA_DIR` to choose the
directory for `veasel.sqlite3`. Remote binding is not implemented. The TUI
accepts `VEASEL_API_URL` only for an unauthenticated loopback HTTP address.
The API also rejects non-loopback `Host` values and browser `Origin` headers
outside loopback hosts.

Agent Plugin packages are discovered from `$VEASEL_PLUGIN_DIR` or
`$VEASEL_DATA_DIR/plugins`. In the TUI, use `/skills` to list discovered
Skills, `/skill on <plugin>/<skill>` to add one to the active session, and
`/skill off <plugin>/<skill>` to remove it. Skill instructions are treated as
untrusted reference context and reloaded from disk for each turn. Install only
plugins you trust. MCP server declarations are shown in metadata but Veasel
does not launch them yet; the project does not claim Agent Plugins conformance.

The initial completion adapters support `openai-compatible` (the default),
`anthropic`, and `gemini`. Set `VEASEL_MODEL_PROVIDER`, `VEASEL_MODEL`, and a
provider key (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, or `GEMINI_API_KEY`;
`VEASEL_MODEL_API_KEY` can override these). `VEASEL_MODEL_BASE_URL` defaults to
the selected provider's API root; custom endpoints must use HTTPS or loopback
HTTP. Keys are read only by the V backend and are never returned by the API.
The TUI sends messages through `/v1/sessions/:id/messages` and reloads the
persisted conversation when a session opens. Provider tool calls run with
bounded workspace list/read/search operations. Streaming, file edits, shell
execution, and durable approvals are not available yet. The backend accepts up
to four provider requests at once; requests reaching the provider gate while
all slots are occupied receive `503 Service Unavailable` with
`Retry-After: 1` instead of joining an unbounded provider queue.

## API

The API uses `/v1/health`, `/v1/capabilities`, `/v1/plugins`, `/v1/sessions`,
`/v1/sessions/:id`, `/v1/sessions/:id/messages`,
`/v1/sessions/:id/workspace/{files,file,search}`, `/v1/chat/completions` when
configured, `/v1/sessions/:id/skills`, and `/v1/events` (SSE). The session
provider tool loop uses the same bounded, read-only workspace operations. See
the OpenAPI document at
[`docs/openapi.yaml`](docs/openapi.yaml).

## Verification

Run `v test .` for the V unit tests and
`scripts/api-smoke.sh` for HTTP validation, session persistence across a
server restart, plugin discovery and session skill activation, and SSE replay. The smoke script requires `curl` and GNU
`timeout`. For memory-bounded local V checks, see [AGENTS.md](AGENTS.md).

See [`docs/VLIB_REUSE.md`](docs/VLIB_REUSE.md) for the checked V standard
library reuse map and [`docs/RESEARCH.md`](docs/RESEARCH.md) for ecosystem and
repository practices. [`docs/security/threat-model.md`](docs/security/threat-model.md)
tracks the current local API boundary, provider disclosure, and the security
gates required before repository tools are enabled. The pinned
[`Agent Plugins v1.0.0 conformance plan`](docs/compatibility/agent-plugins.md)
tracks the compatibility target and required evidence; Veasel does not yet
claim plugin support.

## Licensing

The initial code is MIT licensed. The startup pixel portrait adapts the
official Veasel mascot under CC BY-NC 4.0, which restricts commercial use
without separate permission. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
No endorsement by the V project is implied.

## Community

Read the [contribution guide](CONTRIBUTING.md), [security policy](SECURITY.md),
and [support guide](SUPPORT.md). Organization-wide community standards are in
[veasel-labs/.github](https://github.com/veasel-labs/.github); product
questions and proposals belong in [Discussions](https://github.com/veasel-labs/veasel/discussions).

## Releases

Verified pushes to `main` automatically publish versioned Linux, macOS, and
Windows prereleases with SHA-256 checksums and a build manifest. See the
[release policy](docs/RELEASES.md) and [GitHub Releases](https://github.com/veasel-labs/veasel/releases).
Use `veasel --version` to inspect the version embedded in an installed binary.
