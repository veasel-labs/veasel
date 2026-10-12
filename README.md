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
OpenAI-compatible, Anthropic, or Gemini APIs. Session chat can call bounded
workspace list/read/search tools and propose one-file replacements using
provider-native tool calling for all three provider families. Proposed diffs
are persisted for review; the TUI writes only after an explicit approval.
Requested workspace content is sent to the configured model provider. Shell
commands proposed by the model are stored for review and run only after the exact
command, working directory, and timeout have been opened and explicitly
approved. Approved commands run with the server process user's permissions,
inherit its environment, and have no OS sandbox; they can access files and
network credentials available to that user. Execution is limited to 300 seconds
and 64 KiB of captured output. Interrupted commands are never replayed.
Session turns through all three provider adapters stream text deltas through the
replayable `/v1/events` endpoint. The TUI renders them while a synchronous API
response retains the complete assistant text and provider tool calls. Tool
arguments are assembled before the agent executes them.
The API supports `Prefer: respond-async` for clients that need the request
worker released while a model or human MCP approval is pending. It returns an
operation ID with `202 Accepted`; clients follow `assistant.delta` and the
terminal `session.turn_completed` event or query
`/v1/sessions/{session_id}/operations/{operation_id}`, then reload the committed
session history. Operation state survives reconnects. If the process stops
before recording a result, startup marks the operation `uncertain` and never
replays its provider request or possible tool effects. The worker remains
process-local; durable queued execution and retention remain in progress.
Requests without the preference retain the synchronous response contract.
Local Agent Plugins can be discovered, their validated Skills enabled per
session, and trusted stdio or Streamable HTTP MCP servers exposed as provider
tools. Stdio processes run with the current user's privileges and without an OS
sandbox. HTTP MCP uses the configured origin, refuses redirects, and validates
TLS certificates; configured headers and tool inputs are sent to that endpoint.
The product reports only actual provider replies and does not simulate agent
actions.

## Requirements

- The V compiler revision pinned in `.v-version` (CI installs the exact revision)
- SQLite development headers/library as required by V's `db.sqlite`
- Bun 1.3.14 or newer for the OpenTUI terminal client (not needed by the backend)

## Development

Build the V backend and choose a model directly in the TUI:

```sh
v run .
```

With no subcommand, Veasel reuses a healthy backend at `127.0.0.1:4097`, or
starts `veasel serve` and waits for its health endpoint before opening the TUI.
Press `s` on the home screen, or enter `/models` in an open session, to choose a
provider, model, endpoint, and API key. Provider profiles are stored in
`$VEASEL_DATA_DIR/model-settings.json` with owner-only file permissions on
POSIX systems. Keys are stored locally in plaintext; use environment-based keys
if your machine's local storage policy requires OS-managed secret storage.
Saved provider/model/endpoint profiles take precedence over corresponding
configuration variables; provider API-key environment variables take
precedence over a saved key. Use a separate `VEASEL_DATA_DIR` for isolated
headless configuration.
`veasel serve` remains available to run the backend by itself, and `veasel tui`
also starts or reuses the backend. The TUI accepts `VEASEL_API_URL` only for an
unauthenticated loopback HTTP address.
The API also rejects non-loopback `Host` values and browser `Origin` headers
outside loopback hosts.

Run a non-interactive turn with the same provider configuration, local server,
session database, agent loop, and approval rules:

```sh
veasel run --prompt "Explain the request flow in this repository" --workspace . --json
```

The command creates a durable session, submits an asynchronous turn, polls its
operation state, and emits a JSON object containing the session and operation
IDs, provider/model, completion status, and assistant response. Continue a
conversation with `--session <uuid>`; its prior turns are loaded by the shared
runtime. The wait limit defaults to 30 minutes and is configurable from 1 second
to 24 hours. On timeout, the command requests cancellation and reports both IDs;
provider transports can take time to finish cleanup, so inspect the operation in
the TUI before retrying. Headless mode does not approve or apply proposed edits,
shell commands, or MCP calls; those still require the existing explicit review
flow. It supports unattended read-only tasks, but it is not yet a benchmark
harness that automatically applies patches.

Agent Plugin packages are discovered from `$VEASEL_PLUGIN_DIR` or
`$VEASEL_DATA_DIR/plugins`. In the TUI, use `/skills` to list discovered
Skills, `/skill on <plugin>/<skill>` to add one to the active session, and
`/skill off <plugin>/<skill>` to remove it. Use `/mcp` to inspect MCP server
declarations, `/mcp trust <plugin>/<server>` to allow a server for the session,
and `/mcp untrust <plugin>/<server>` to revoke it. Trusted stdio processes run
with the current user's OS privileges without a sandbox. Streamable HTTP sends
configured headers and tool requests only to the displayed origin and refuses
redirects. Tool arguments and results are sent to the configured model provider.
A stdio process is launched for discovery and remains available for the model
turn; only `PLUGIN_DATA` persists between turns.
Every model-requested MCP call pauses the active turn until you inspect the
exact tool arguments with `/mcp calls` and `/mcp call show <id>`, then approve
with `/mcp call approve <id>` or reject with `/mcp call reject <id>`. Rejected
calls are not retried. Calls interrupted before execution are cancelled; calls
whose execution outcome cannot be known after a restart are marked uncertain
and never replayed.
Skill instructions are treated as untrusted reference context and reloaded
from disk for each turn. When a Skill is active, the model can request bounded
UTF-8 resources from that Skill's directory through a read-only tool; paths
cannot escape the directory, and resource contents are untrusted. Skill scripts
are never executed automatically. Experimental Skill `allowed-tools`
declarations can only restrict exact Veasel tool names for the active session;
they never add tools or bypass MCP trust, file approval, or shell approval.
Install only plugins you trust. Agent Plugins support is experimental and does
not claim full v1.0.0 conformance.

The completion adapters support `openai-compatible`, `openai`, `anthropic`,
and `gemini`. Configure provider profiles in the TUI, or use
`VEASEL_MODEL_PROVIDER`, `VEASEL_MODEL`, `VEASEL_MODEL_BASE_URL`, and a provider
key (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, or `GEMINI_API_KEY`; the shared
`VEASEL_MODEL_API_KEY` also works). Environment configuration remains available
for scripts and headless use. Custom endpoints must use HTTPS or loopback HTTP.
Keys are never returned by the API.
The TUI sends messages through `/v1/sessions/:id/messages` and reloads the
persisted conversation when a session opens. Enter `/history older` in a
session to load its preceding 100 messages without losing the visible history.
Provider tool calls run with
bounded workspace list/read/search operations. Veasel can propose a complete
single-file edit; the TUI shows its unified diff with `/patches` and
`/patch show <id>`, and writes only after that diff has been opened and
`/patch approve <id>` is entered. Review and application states persist locally.
Stale proposals are rejected, and an
interrupted write is never replayed automatically. Commands can be reviewed
with `/commands`, inspected with `/command show <id>`, then approved or rejected
with `/command approve <id>` or `/command reject <id>`. Execution inherits the
server process environment, is not sandboxed, and requires review of any
filesystem, network, and credential effects. See the
[`shell command security model`](docs/SHELL_COMMANDS.md) before enabling this
workflow.
Press Escape while a response is running to
cancel its operation; session requests may also provide an
`X-Veasel-Operation-ID` UUID and call the session cancellation endpoint. Turns
have a two-minute deadline. A cancelled API request returns promptly, while a
provider request keeps its slot until a response chunk observes cancellation or
the bounded V HTTP timeout expires. Cancellation before the first response chunk
still waits for that bounded transport cleanup. Direct `/v1/chat/completions` calls
use the matching `/v1/operations/:id/cancel` endpoint. The backend accepts up to four
provider requests at once; requests reaching the provider gate while all slots
are occupied receive `503 Service Unavailable` with `Retry-After: 1` instead of
joining an unbounded provider queue.

On POSIX systems, approved replacements preserve the target's permission bits.
ACLs and extended attributes are not currently copied to the replacement file.

## API

The API uses `/v1/health`, `/v1/capabilities`, `/v1/plugins`, `/v1/sessions`,
`/v1/sessions/:id`, `/v1/sessions/:id/messages`,
`/v1/sessions/:id/workspace/{files,file,search,edits,commands}`, `/v1/chat/completions`
when configured, `/v1/sessions/:id/skills`, and `/v1/events` (SSE). The session
provider tool loop uses bounded reads and creates durable, reviewable single-file
edit proposals. File writes require an explicit approval request. See
the OpenAPI document at
[`docs/openapi.yaml`](docs/openapi.yaml).
Agent Toolkit clients should follow the [integration contract](docs/integrations/agent-toolkit.md),
which records ownership, API routes, local-only access, and smoke-test coverage.

## Verification

Run `v test .` for the V unit tests and
`scripts/api-smoke.sh` for HTTP validation, session persistence across a
server restart, plugin discovery and session skill activation, and SSE replay.
The smoke also completes a disposable coding task with each provider: it
inspects and approves a proposed diff, runs the fixture's V test, and verifies
that unreviewed shell commands and rejected edits leave no filesystem effects.
The script requires `curl` and GNU `timeout`. For memory-bounded local V checks, see
[AGENTS.md](AGENTS.md).

See [`docs/VLIB_REUSE.md`](docs/VLIB_REUSE.md) for the checked V standard
library reuse map and [`docs/RESEARCH.md`](docs/RESEARCH.md) for ecosystem and
repository practices. [`docs/security/threat-model.md`](docs/security/threat-model.md)
tracks the current local API boundary, provider disclosure, and the security
gates required before repository tools are enabled. The pinned
[`Agent Plugins v1.0.0 conformance plan`](docs/compatibility/agent-plugins.md)
tracks the compatibility target and required evidence; Veasel's Agent Plugins
integration remains experimental and does not claim full conformance.
Release compiler selection, production flags, and benchmark build provenance
are documented in [`docs/V_BUILD_PROFILE.md`](docs/V_BUILD_PROFILE.md).
Headless ATIF export and the limits of current benchmark readiness are
documented in [`docs/benchmarking.md`](docs/benchmarking.md).

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
