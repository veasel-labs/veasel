# HTTP cancel limits under pinned `net.http`

**Pinned V:** `.v-version` (`cbe6ea8bbbc30ff7630eac5f507809182bfa027c`)
**Surfaces:** provider SSE (`provider.v`), Agent Plugin / configured MCP
Streamable HTTP (`plugin_mcp_http_transport.v`)

## What Veasel cancels today

| Stage | Behavior |
|---|---|
| Before `http.fetch` | Cancel is re-checked after header assembly; no socket is opened. |
| First response bytes | `on_progress` / `on_progress_body` abort with `cancelled` (status line and header bytes count as progress). |
| Mid-body | Progress callbacks abort; MCP emits best-effort `notifications/cancelled`. |
| After fetch returns | Cancel is re-checked before delivering RPC / finishing provider SSE decode. |

Stdio MCP still uses `notifications/cancelled` when a turn cancels mid-call.

## Hard limit (cannot observe true TTFB cancel)

Pinned `net.http.fetch` exposes no external cancel handle and no dial/TTFB
callback. Between the start of `fetch` and the first progress callback (no
socket bytes yet — DNS/dial/TLS/server-think), Veasel cannot close the socket
or interrupt the wait. Cancel remains sticky: the in-flight call aborts on the
first progress byte or when the configured read timeout elapses.

This is a stdlib boundary, not a missing Veasel permission check. Replacing it
would require a custom HTTP stack (for example fasthttp), which is deferred.

## Evidence

- `plugin_mcp_cancel_test.v` — cancel before send / listen
- `plugin_mcp_http_transport_test.v:test_plugin_mcp_http_transport_cancels_on_first_progress_after_slow_ttfb`
- `main_test.v:test_provider_sse_progress_aborts_on_cancel_before_2xx_decode`
