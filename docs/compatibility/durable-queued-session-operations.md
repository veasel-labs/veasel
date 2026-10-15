# Durable queued session operations

Veasel persists `Prefer: respond-async` session turns in SQLite before accepting
the HTTP response. This note records the competitive principles consulted and
the recovery contract Veasel implements.

## Upstream pins consulted (principles only)

| Project | Commit | What was inspected | Adopted into Veasel? |
| --- | --- | --- | --- |
| [OpenCode](https://github.com/anomalyco/opencode/tree/37df62f4a1b6d89187a1169187a6cef10557c0ca) | `37df62f4a1b6d89187a1169187a6cef10557c0ca` | Session runner / step lifecycle: durable session identity with bounded steps | Principle only: persist before work, reconnectable status |
| [OpenHands Agent Server](https://github.com/OpenHands/software-agent-sdk/tree/8efff8d3cf1a5a3fcf7ce5e3b97c7f00684d9547) | `8efff8d3cf1a5a3fcf7ce5e3b97c7f00684d9547` | `event_service.py` conversation leases, resume prompts, pub/sub fan-out | Principle only: resume queued work; do not pretend mid-flight provider calls are safe to replay |
| [Pi](https://github.com/badlogic/pi-mono) (prior study) | `b06c1f2cf1dea6af8748ddeee18c23587d2cb7c6` | Durable session document layer | Principle only: durable state ≠ automatic effect replay |

No OpenCode, OpenHands, or Pi source was copied. Contracts remain Veasel's
loopback HTTP API (`queued` → `running` → terminal).

## Recovery contract

| Persisted status at crash | On next startup | Rationale |
| --- | --- | --- |
| `queued` | Kept and resumed by a worker that claims to `running`, after request/workspace/model checks | Request JSON is durable; no provider or tool effect has started. Missing workspace, invalid request, or unset model fail closed as `cancelled` without claim |
| `running` / `cancelling` | Marked `uncertain`; never replayed | Provider socket or tool side effects may have completed without a durable result |
| Terminal (`completed` / `failed` / `cancelled` / `uncertain`) | Unchanged; oldest terminal rows pruned beyond 200 per session | Bounded retention |

## API surface

- Enqueue: `POST /v1/sessions/{id}/messages` with `Prefer: respond-async` → `202` + `status: queued`
- List: `GET /v1/sessions/{id}/operations`
- Get / cancel / result: existing operation routes
- Events: `session.turn_queued`, then `session.turn_started`, then `session.turn_completed`
- Capabilities: `sessions.operations.durable_queue`, `sessions.operations.list`
- Bound: at most 32 `queued` rows per session; further enqueues return `503` with
  `Retry-After: 1` and do not persist another queue row

Approvals for edits, shell, and MCP remain mandatory. Loopback Host/Origin
defaults are unchanged. Cancel of a `queued` row is terminal without starting a
provider call.
