/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { LiveApp } from "./live-app"
import { VeaselApiClient } from "../api-client"

test("queues a follow-up and cancels it without affecting the active turn", async () => {
  const posts: string[] = []
  const cancellations: string[] = []
  const cancellationStatuses = new Map<string, string>()
  const controller = new AbortController()
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request) {
      const path = new URL(request.url).pathname
      if (path === "/v1/events") return new Response(new ReadableStream({
        start(stream) { stream.enqueue(new TextEncoder().encode(": connected\n\n")) },
      }), { headers: { "content-type": "text/event-stream" } })
      if (path === "/v1/sessions") {
        return Response.json([{ id: "s1", title: "Session alpha", directory: "/tmp" }])
      }
      if (path.endsWith("/cancel")) {
        cancellations.push(path)
        const operationId = path.split("/").at(-2)
        return Response.json({
          operation_id: operationId,
          status: cancellationStatuses.get(operationId ?? "")
            ?? (operationId === posts.at(-1) ? "cancelled" : "cancelling"),
        }, { status: 202 })
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

    cancellationStatuses.set(queuedId, "completed")
    setup.mockInput.pressKey("x", { ctrl: true, shift: true })
    await until(() => cancellations.length === 1)
    await until(() => !setup.captureCharFrame().includes("Follow-up turn"))
    expect(cancellations).toEqual([`/v1/sessions/s1/operations/${queuedId}/cancel`])

    setup.mockInput.typeText("Next follow-up")
    setup.mockInput.pressEnter()
    await until(() => posts.length === 3)
    const nextQueuedId = posts[2]
    cancellationStatuses.set(nextQueuedId, "cancelled")
    setup.mockInput.pressKey("x", { ctrl: true, shift: true })
    await until(() => cancellations.length === 2)
    await until(() => !setup.captureCharFrame().includes("Next follow-up"))
    setup.mockInput.pressKey("x", { ctrl: true, shift: true })
    await setup.renderOnce()
    expect(cancellations).toHaveLength(2)

    setup.mockInput.pressKey("x", { ctrl: true })
    await until(() => cancellations.length === 3)
    expect(cancellations).toEqual([
      `/v1/sessions/s1/operations/${queuedId}/cancel`,
      `/v1/sessions/s1/operations/${nextQueuedId}/cancel`,
      `/v1/sessions/s1/operations/${firstId}/cancel`,
    ])
  } finally {
    controller.abort()
    setup.renderer.destroy()
    server.stop(true)
  }
})
