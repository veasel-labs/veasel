/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { LiveApp } from "./live-app"
import { VeaselApiClient } from "../api-client"

test("queues a follow-up without replacing the active turn, then promotes it", async () => {
  const posts: string[] = []
  const cancellations: string[] = []
  let events!: ReadableStreamDefaultController<Uint8Array>
  const controller = new AbortController()
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request) {
      const path = new URL(request.url).pathname
      if (path === "/v1/events") return new Response(new ReadableStream({
        start(stream) {
          events = stream
          stream.enqueue(new TextEncoder().encode(": connected\n\n"))
        },
      }), { headers: { "content-type": "text/event-stream" } })
      if (path === "/v1/sessions") {
        return Response.json([{ id: "s1", title: "Session alpha", directory: "/tmp" }])
      }
      if (path.endsWith("/cancel")) {
        cancellations.push(path)
        return Response.json({ operation_id: posts.at(-1), status: "cancelling" }, { status: 202 })
      }
      if (path.endsWith("/messages")) {
        if (request.method === "POST") {
          posts.push(request.headers.get("x-veasel-operation-id") ?? "")
          return Response.json({ operation_id: posts.at(-1), status: "running" }, { status: 202 })
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
    for (let attempt = 0; attempt < 100; attempt++) {
      await setup.renderOnce()
      if (predicate()) return
      await Bun.sleep(5)
    }
    throw new Error("Expected queued turn state was not reached")
  }

  try {
    await until(() => setup.captureCharFrame().includes("Session alpha"))
    setup.mockInput.pressEnter()
    await setup.renderOnce()
    await setup.mockInput.typeText("First turn")
    setup.mockInput.pressEnter()
    await until(() => posts.length === 1)
    setup.mockInput.typeText("Follow-up turn")
    setup.mockInput.pressEnter()
    await until(() => posts.length === 2)
    await until(() => setup.captureCharFrame().includes("Follow-up turn"))
    const [firstId, queuedId] = posts
    expect(queuedId).not.toBe(firstId)

    events.enqueue(new TextEncoder().encode(
      `event: session.turn_completed\ndata: ${JSON.stringify({
        session_id: "s1", data: { operation_id: firstId, status: "completed" },
      })}\n\n` +
      `event: session.turn_started\ndata: ${JSON.stringify({
        session_id: "s1", data: { operation_id: queuedId, status: "running" },
      })}\n\n`,
    ))
    await until(() => setup.captureCharFrame().includes("queued follow-up"))
    setup.mockInput.pressKey("x", { ctrl: true })
    await until(() => cancellations.length === 1)
    expect(cancellations).toEqual([`/v1/sessions/s1/operations/${queuedId}/cancel`])
  } finally {
    controller.abort()
    setup.renderer.destroy()
    server.stop(true)
  }
})
