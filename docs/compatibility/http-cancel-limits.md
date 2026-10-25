# HTTP cancel limits under pinned `net.http`

**Pinned V:** `.v-version` (`ffc38ada48df34cbf3aa818c3410ce7fcdef5c1f`, V 0.5.2)
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

Pinned [`net.http.FetchConfig`](https://github.com/vlang/v/blob/ffc38ada48df34cbf3aa818c3410ce7fcdef5c1f/vlib/net/http/http.v)
exposes a read timeout and response-progress callbacks, but no external cancel
handle or dial/TTFB callback. [`Request.on_progress`](https://github.com/vlang/v/blob/ffc38ada48df34cbf3aa818c3410ce7fcdef5c1f/vlib/net/http/request.v)
runs only after socket bytes arrive. Between the start of `fetch` and the first
progress callback (DNS/dial/TLS/server-think), Veasel cannot close the socket or
interrupt the wait. Cancel remains sticky: the in-flight call aborts on the
first progress byte or when the configured read timeout elapses.

This is a stdlib boundary, not a missing Veasel permission check. Replacing it
would require a custom HTTP stack (for example fasthttp), which is deferred.

## Evidence

- `plugin_mcp_cancel_test.v` — cancel before send / listen
- `plugin_mcp_http_transport_test.v:test_plugin_mcp_http_transport_cancels_on_first_progress_after_slow_ttfb`
- `main_test.v:test_provider_sse_progress_aborts_on_cancel_before_2xx_decode`
