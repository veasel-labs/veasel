/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { LiveApp } from "./live-app"
import { VeaselApiClient } from "../api-client"

for (const staleFailure of [false, true]) {
  test(`session navigation ignores stale ${staleFailure ? "errors" : "history"} after A -> B -> A`, async () => {
    let release!: () => void
    const gate = new Promise<void>((resolve) => { release = resolve })
    let aRequests = 0
    let bRequests = 0
    let firstResponded = false
    const controller = new AbortController()
    const server = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      async fetch(request) {
        const path = new URL(request.url).pathname
        if (path === "/v1/events") {
          return new Response(new ReadableStream({
            start(stream) { stream.enqueue(new TextEncoder().encode(": connected\n\n")) },
          }), { headers: { "content-type": "text/event-stream" } })
        }
        if (path === "/v1/sessions") return Response.json([
          { id: "a", title: "Session alpha", directory: "/tmp" },
          { id: "b", title: "Session beta", directory: "/tmp" },
        ])
        if (path.endsWith("/messages")) {
          const id = path.includes("/a/") ? "a" : "b"
          const count = id === "a" ? ++aRequests : ++bRequests
          if (id === "a" && count === 1) {
            await gate
            firstResponded = true
            if (staleFailure) return new Response("old failure", { status: 503 })
          }
          return Response.json([{
            id: count, session_id: id, role: "assistant",
            content: id === "a" && count === 1 ? "Obsolete alpha response" : `Current ${id} history`,
            created_at: "2026-10-17T00:00:00Z",
          }])
        }
        return Response.json({})
      },
    })
    const setup = await testRender(() => (
      <LiveApp api={new VeaselApiClient(server.url.origin, controller.signal)} directory="/tmp" />
    ), { width: 100, height: 32, kittyKeyboard: true })
    async function until(predicate: () => boolean) {
      for (let attempt = 0; attempt < 100; attempt++) {
        await setup.renderOnce()
        if (predicate()) return
        await Bun.sleep(5)
      }
      throw new Error("Expected live UI state was not reached")
    }
    try {
      await until(() => setup.captureCharFrame().includes("Session alpha"))
      setup.mockInput.pressEnter()
      await until(() => aRequests === 1)
      setup.mockInput.pressKey("]", { ctrl: true })
      await until(() => setup.captureCharFrame().includes("Current b history"))
      setup.mockInput.pressKey("[", { ctrl: true })
      await until(() => setup.captureCharFrame().includes("Current a history"))
      release()
      await until(() => firstResponded)
      // Let the fetch consumer apply (or discard) the released response.
      await Bun.sleep(20)
      await setup.renderOnce()
      expect(setup.captureCharFrame()).toContain("Current a history")
      expect(setup.captureCharFrame()).not.toContain("Obsolete alpha response")
      expect(setup.captureCharFrame()).not.toContain("could not open session")
      expect(aRequests).toBe(2)
    } finally {
      release()
      controller.abort()
      setup.renderer.destroy()
      server.stop(true)
    }
  })
}
