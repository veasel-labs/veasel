# OpenCode API compatibility matrix

**Comparison revision:** [`95daf90670b7c039c436c85537da5fbfe2205b41`](https://github.com/anomalyco/opencode/tree/95daf90670b7c039c436c85537da5fbfe2205b41)
**Revision date:** 2026-09-11
**Comparison date:** 2026-10-09
**Purpose:** Track observable contract overlap. This is not a claim of OpenCode
API compatibility and does not authorize copying implementation code.

The pinned OpenCode API surface is defined in its
[`session` route group](https://github.com/anomalyco/opencode/blob/95daf90670b7c039c436c85537da5fbfe2205b41/packages/opencode/src/server/routes/instance/httpapi/groups/session.ts)
and [`event` route group](https://github.com/anomalyco/opencode/blob/95daf90670b7c039c436c85537da5fbfe2205b41/packages/opencode/src/server/routes/instance/httpapi/groups/event.ts).
The current implementation surface is declared by `openapi.yaml`, `api.v`,
`provider.v`, and `store.v` in this repository.

| Capability | Pinned OpenCode contract | Veasel contract | Status | Gap before claiming compatibility |
|---|---|---|---|---|
| Health and version | No equivalent route in the inspected session/event groups. | `GET /v1/health`, response `{ healthy, version }`. | Veasel-specific | None if kept outside a compatibility namespace. |
| Capability discovery | No equivalent route in the inspected groups. | `GET /v1/capabilities`, version and feature names. | Veasel-specific | None if kept outside a compatibility namespace. |
| Session list/create/get | `/session` and `/session/:sessionID`; OpenCode schemas and query fields are richer. | `/v1/sessions`, `/v1/sessions/:id`; Veasel uses its own session fields and JSON schemas. | Partial concept overlap; wire-incompatible | Match route prefix, parameters, schema, filtering, pagination, and status/error behavior. |
| Session messages | `GET` and `POST /session/:sessionID/message`; messages contain typed `info` and `parts` structures. | `/v1/sessions/:id/messages`; flat persisted `{ role, content }` turns and a single user-content request. | Not compatible | Define and test message/part schemas, request shape, ordering, and response semantics. |
| Events | `GET /event` returns a `text/event-stream` subscription. | `GET /v1/events` emits Veasel event IDs and JSON event payloads. | Partial transport overlap; event schema differs | Compare event envelopes, names, replay cursors, heartbeat, disconnect, and error semantics. |
| Provider selection | Provider/model identifiers participate in prompt payloads and server configuration. | Provider/model selection is environment-configured; completion returns provider/model/content. | Not compatible | Add provider catalog/config contracts and match model identifiers and errors only if needed. |
| Permissions and approvals | Session permission responses use permission IDs and reply schemas. | File edits are persisted as single-use proposals and require explicit TUI approval. Shell proposals bind approval to the exact command, working directory, and timeout. OpenCode permission IDs and reply schemas are not implemented. | Product capability exists; wire-incompatible | Implement protocol-compatible permission IDs/reply schemas only if this compatibility target is required; retain exact-operation binding and test the protocol separately. |
| Abort/cancel | `POST /session/:sessionID/abort`. | Veasel exposes cancellation routes for session turns and direct completions using operation IDs. Cancellation propagates through turn contexts and queued work. The provider transport uses bounded timeouts but cannot close an in-flight socket immediately before its first response chunk. | Product cancellation exists; route and transport semantics differ | Add the OpenCode route and match its response/state behavior only if required; define and test transport cancellation races before claiming equivalent interruption. |
| Tool execution | Session messages can encode tool parts; routes include commands and shell. | Providers support a bounded native tool loop. Workspace list/read/search are read-only; file changes and shell commands are proposals requiring explicit approval. Trusted Agent Plugin MCP tools can run with the user's OS privileges. | Product capability exists; tool and event schemas are wire-incompatible | Add OpenCode-compatible tool parts, route contracts, results, and permission enforcement only if this compatibility target is required. |

## Rules for updating this matrix

- Refresh the pinned revision when a compatibility task begins; do not silently
  treat `main` or `dev` as stable contracts.
- Link the exact upstream schema/source file and exact commit for every added
  row. Record provider/model versions where behavior is model-dependent.
- Add a contract fixture and automated comparison before changing a row to
  “compatible.” Similar route names or user-visible behavior are insufficient.
- Keep Veasel-specific endpoints under `/v1`; expose compatibility routes only
  as an explicit, tested surface.
- Do not copy source code as part of contract comparison. Record source license
  and notices before any separately reviewed reuse.
