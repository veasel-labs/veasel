// Drives the real TUI auth wrapper against a running backend. Used by
// scripts/auth-lifecycle-smoke.py; prints one JSON object.
//
//   bun run scripts/auth-lifecycle-tui-probe.ts <stale-token-or-"">
//
// With a stale token the first token read returns it (a client that cached the
// value before rotation); later reads come from the data-dir file like the
// real TUI. The wrapper must recover with exactly one retry.
import { resolveLoopbackApiBase } from "../tui/src/api-client"
import { createApiTokenSource, withBackendAuth } from "../tui/src/backend-auth"

const stale = process.argv[2] ?? ""
const base = resolveLoopbackApiBase()
const fromFile = createApiTokenSource()
let first = stale.length > 0
let requests = 0
const counting = (async (input: RequestInfo | URL, init?: RequestInit) => {
  requests++
  return fetch(input, init)
}) as typeof fetch
const source = () => {
  if (first) {
    first = false
    return stale
  }
  return fromFile()
}
const wrapped = withBackendAuth(base, source, counting)
const sessions = await wrapped(`${base}/v1/sessions`)
const events = await wrapped(`${base}/v1/events`, { headers: { accept: "text/event-stream" } })
await events.body?.cancel()
console.log(JSON.stringify({ sessions: sessions.status, events: events.status, requests }))
