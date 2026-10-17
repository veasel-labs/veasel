/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { LiveApp } from "./live-app"
import { VeaselApiClient } from "../api-client"

for (const [outcome, message] of [
  ["cancelled", "Turn cancelled"],
  ["failed", "Assistant turn failed"],
  ["uncertain", "Outcome uncertain"],
]) {
test(`Ctrl+X targets the originating session and reports ${outcome}`, async () => {
  let operationId = ""
  const cancellations: string[] = []
  let events!: ReadableStreamDefaultController<Uint8Array>
  const controller = new AbortController()
  const server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    fetch(request) {
      const path = new URL(request.url).pathname
      if (path === "/v1/events") return new Response(new ReadableStream({
        start(stream) {
          events = stream
          stream.enqueue(new TextEncoder().encode(": connected\n\n"))
        },
      }), { headers: { "content-type": "text/event-stream" } })
      if (path === "/v1/sessions") return Response.json([
        { id: "a", title: "Session alpha", directory: "/tmp" },
        { id: "b", title: "Session beta", directory: "/tmp" },
      ])
      if (path.endsWith("/cancel")) {
        cancellations.push(path)
        return Response.json({ operation_id: operationId, status: "cancelling" }, { status: 202 })
      }
      if (path.endsWith("/messages")) {
        if (request.method === "POST") {
          operationId = request.headers.get("x-veasel-operation-id")!
          return Response.json({ operation_id: operationId, status: "running" }, { status: 202 })
        }
        return Response.json([])
      }
      return Response.json({})
    },
  })
  const setup = await testRender(() => (
    <LiveApp api={new VeaselApiClient(server.url.origin, controller.signal)} directory="/tmp" />
  ), { width: 100, height: 32, kittyKeyboard: true })
  async function until(predicate: () => boolean) {
    for (let n = 0; n < 100; n++) {
      await setup.renderOnce()
      if (predicate()) return
      await Bun.sleep(5)
    }
    throw new Error("Expected cancellation state was not reached")
  }
  try {
    await until(() => setup.captureCharFrame().includes("Session alpha"))
    setup.mockInput.pressEnter()
    await setup.renderOnce()
    await setup.mockInput.typeText("Do some work")
    setup.mockInput.pressEnter()
    await until(() => Boolean(operationId))
    setup.mockInput.pressKey("]", { ctrl: true })
    await setup.renderOnce()
    setup.mockInput.pressKey("x", { ctrl: true })
    await until(() => setup.captureCharFrame().includes("Cancellation requested"))
    setup.mockInput.pressKey("x", { ctrl: true })
    await setup.renderOnce()
    expect(cancellations).toEqual([`/v1/sessions/a/operations/${operationId}/cancel`])
    expect(setup.captureCharFrame()).not.toContain("Turn cancelled")
    setup.mockInput.pressKey("[", { ctrl: true })
    await setup.renderOnce()
    events.enqueue(new TextEncoder().encode(
      `event: session.turn_completed\ndata: ${JSON.stringify({
        session_id: "a", data: { operation_id: operationId, status: outcome },
      })}\n\n`,
    ))
    await until(() => setup.captureCharFrame().includes(message!))
    setup.mockInput.pressKey("x", { ctrl: true })
    await setup.renderOnce()
    expect(cancellations).toHaveLength(1)
  } finally {
    controller.abort()
    setup.renderer.destroy()
    server.stop(true)
  }
})

}

test("cancellation HTTP failure is surfaced to the caller", async () => {
  const server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    fetch() { return new Response("not cancelled", { status: 503 }) },
  })
  try {
    await expect(new VeaselApiClient(server.url.origin).cancelOperation("s", "o"))
      .rejects.toThrow("HTTP 503")
  } finally {
    server.stop(true)
  }
})
