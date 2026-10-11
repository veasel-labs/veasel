# Agent Toolkit integration contract

This document defines the supported boundary for Agent Toolkit clients that
need Veasel Code to execute a coding session. It describes a client using
Veasel's versioned HTTP API; it does not claim that the Agent Toolkit CLI ships
a Veasel adapter today.

## Ownership

Agent Toolkit owns reusable skills, agents, MCP templates, and capability
distribution. Veasel owns the coding session, provider requests, workspace
tools, plugin discovery, per-session Skill selection, MCP trust, and review of
tool effects. Agent Toolkit can prepare or distribute an Agent Plugin package;
Veasel discovers packages from `VEASEL_PLUGIN_DIR` or
`$VEASEL_DATA_DIR/plugins` and does not install, update, or remove them.

Clients must use Veasel's HTTP API and event stream. They must not read or write
Veasel's SQLite database or depend on internal V modules. The contract source
is [`../openapi.yaml`](../openapi.yaml); use `/v1/capabilities` to discover
features and handle unsupported features without guessing from the Veasel
version string.

## Client flow

1. `GET /v1/health` and `GET /v1/capabilities` before opening a session.
2. `GET /v1/plugins` to list locally discovered plugin metadata and diagnostics.
   The catalog excludes Skill instruction bodies, MCP URL paths and queries,
   and HTTP header values; it returns only the parsed HTTP origin and header
   names.
3. `POST /v1/sessions` with an existing workspace directory, then retain the
   returned session ID.
4. `GET` and `POST /v1/sessions/{id}/skills` to inspect or change that session's
   Skill selection. The POST body is `{ "plugin_name", "skill_name",
   "enabled" }`; enabling an unknown or invalid Skill fails.
5. `GET` and `POST /v1/sessions/{id}/mcp-servers` to inspect or change trust.
   The POST body is `{ "plugin_name", "server_name", "trusted" }`. A newly
   trusted server connects on the next model turn. A session can trust at most
   eight MCP servers; exceeding the limit returns `409`.
6. Subscribe to `GET /v1/events` and use its event ID when reconnecting. For
   async turns, retain the operation ID and poll the session-scoped operation
   endpoint after reconnect or restart. Work interrupted by a server restart
   is reported as `uncertain` and is not replayed.
7. For a model-requested MCP call, list pending calls, fetch the exact call
   detail to durably record inspection, then explicitly approve or reject.
   Approval before inspection returns `409`; inspection alone does not execute
   the server call. Client applications should present this review to a person
   before sending the approval request.

The durable schemas, request bodies, status codes, and response shapes are
defined in OpenAPI. Treat IDs as opaque, preserve unknown response fields, and
do not rely on map ordering. A `404` for an unknown session or MCP call, or a
missing Skill when enabling it, is a domain result. Invalid requests and
unsupported MCP declarations return `400`.

## Local boundary and safety

Veasel currently binds to loopback and does not implement remote API binding or
bearer authentication. An Agent Toolkit client must run on the same host and
connect to the configured loopback address. Do not expose the port through a
LAN, reverse proxy, or tunnel. Browser clients must also obey Veasel's loopback
`Host` and `Origin` checks.

Skill instructions and resource files are untrusted model context. MCP trust is
per session, and every model-requested MCP call requires durable inspection and
explicit approval through the API. Trusted MCP processes run with the Veasel
server user's OS privileges and inherited environment, without an OS sandbox;
MCP arguments and results are sent to the configured model provider. Agent
Toolkit's own mutation confirmation does not replace Veasel's per-call approval,
and Veasel's approval does not grant permission to install or mutate Agent
Toolkit capabilities.

## Verification

`scripts/api-smoke.sh` is the executable integration contract. It starts Veasel
with a disposable Agent Plugin fixture and verifies plugin/Skill catalog shape,
session Skill activation and restart persistence, MCP trust and approval, and
that rejected or unreviewed calls have no fixture effects. CI runs this smoke
on Linux; the V API tests cover the session-bound state transitions. The
contract is considered broken if these checks fail or the corresponding
OpenAPI route/schema changes without updating this document.

Agent Toolkit security and API architecture references:

- [`agent_toolkit_server/server.veb.v`](https://github.com/ulises-jeremias/agent-toolkit/blob/main/modules/agent_toolkit_server/server.veb.v)
  keeps HTTP routing separate from typed core operations and validates host,
  authentication, and mutation policy.
- [`RESEARCH.md`](../RESEARCH.md#agent-toolkit-and-workspace-patterns) records
  the local source review and the integration ownership boundary.
