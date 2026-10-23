/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { LiveApp } from "./live-app"
import { VeaselApiClient } from "../api-client"

test("queues a follow-up and cancels it without affecting the active turn", async () => {
  const posts: string[] = []
  const cancellations: string[] = []
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
      if (path === "/v1/sessions/s1/operations") return Response.json([])
      if (path.endsWith("/cancel")) {
        cancellations.push(path)
        const operationId = path.split("/").at(-2)
        return Response.json({
          operation_id: operationId,
          status: operationId === posts.at(-1) ? "cancelled" : "cancelling",
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
    setup.mockInput.typeText("Last follow-up")
    setup.mockInput.pressEnter()
    await until(() => posts.length === 3)
    await until(() => setup.captureCharFrame().includes("Last follow-up"))
    const [firstId, earlierQueuedId, queuedId] = posts
    expect(earlierQueuedId).not.toBe(firstId)
    expect(queuedId).not.toBe(earlierQueuedId)

    setup.mockInput.pressKey("x", { ctrl: true, shift: true })
    await until(() => cancellations.length === 1)
    await until(() => !setup.captureCharFrame().includes("Last follow-up"))
    expect(setup.captureCharFrame()).toContain("Follow-up turn")
    expect(cancellations).toEqual([`/v1/sessions/s1/operations/${queuedId}/cancel`])

    setup.mockInput.pressKey("x", { ctrl: true })
    await until(() => cancellations.length === 2)
    expect(cancellations).toEqual([
      `/v1/sessions/s1/operations/${queuedId}/cancel`,
      `/v1/sessions/s1/operations/${firstId}/cancel`,
    ])
  } finally {
    controller.abort()
    setup.renderer.destroy()
    server.stop(true)
  }
})

async function mountDurableOperation(status: "queued" | "running" | "uncertain") {
  const operationId = `${status}-after-restart`
  const cancellations: string[] = []
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
      if (path === "/v1/sessions/s1/operations") {
        return Response.json([{
          id: operationId,
          session_id: "s1",
          status,
          provider: "",
          model: "",
          error: "",
          created_at: "2026-10-23T00:00:00Z",
          updated_at: "2026-10-23T00:00:00Z",
        }])
      }
      if (path.endsWith("/cancel")) {
        cancellations.push(path)
        return Response.json({
          operation_id: operationId,
          status: status === "queued" ? "cancelled" : "cancelling",
        }, { status: 202 })
      }
      if (path.endsWith("/messages")) return Response.json([])
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
    throw new Error(`Expected ${status} operation to be restored`)
  }

  await until(() => setup.captureCharFrame().includes("Session alpha"))
  setup.mockInput.pressEnter()
  await until(() => setup.captureCharFrame().includes(
    status === "queued"
      ? "1 follow-up queued"
      : status === "running"
        ? "Veasel is working"
        : "Outcome uncertain",
  ))
  return {
    setup,
    cancellations,
    operationId,
    until,
    dispose() {
      controller.abort()
      setup.renderer.destroy()
      server.stop(true)
    },
  }
}

test("restores a durable queued turn when opening a session", async () => {
  const harness = await mountDurableOperation("queued")
  try {
    harness.setup.mockInput.pressKey("x", { ctrl: true, shift: true })
    await harness.until(() => harness.cancellations.length === 1)
    expect(harness.cancellations).toEqual([
      `/v1/sessions/s1/operations/${harness.operationId}/cancel`,
    ])
  } finally {
    harness.dispose()
  }
})

test("restores an active durable turn when opening a session", async () => {
  const harness = await mountDurableOperation("running")
  try {
    harness.setup.mockInput.pressKey("x", { ctrl: true })
    await harness.until(() => harness.cancellations.length === 1)
    expect(harness.cancellations).toEqual([
      `/v1/sessions/s1/operations/${harness.operationId}/cancel`,
    ])
  } finally {
    harness.dispose()
  }
})

test("warns when the latest durable turn has an uncertain outcome", async () => {
  const harness = await mountDurableOperation("uncertain")
  try {
    expect(harness.setup.captureCharFrame()).toContain("Outcome uncertain")
    expect(harness.setup.captureCharFrame()).toContain("inspect the workspace before retrying")
  } finally {
    harness.dispose()
  }
})

test("prefers a live start event over a stale queued operation snapshot", async () => {
  const operationId = "starts-during-recovery"
  const cancellations: string[] = []
  const controller = new AbortController()
  let events!: ReadableStreamDefaultController<Uint8Array>
  let releaseOperations!: (response: Response) => void
  let operationsRequested = false
  const operationsResponse = new Promise<Response>((resolve) => { releaseOperations = resolve })
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
      if (path === "/v1/sessions/s1/operations") {
        operationsRequested = true
        return operationsResponse
      }
      if (path.endsWith("/cancel")) {
        cancellations.push(path)
        return Response.json({ operation_id: operationId, status: "cancelling" }, { status: 202 })
      }
      if (path.endsWith("/messages")) return Response.json([])
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
    throw new Error("Expected live operation state to win over the stale snapshot")
  }

  try {
    await until(() => setup.captureCharFrame().includes("Session alpha"))
    setup.mockInput.pressEnter()
    await until(() => operationsRequested)
    events.enqueue(new TextEncoder().encode(
      `event: session.turn_started\ndata: ${JSON.stringify({
        session_id: "s1", data: { operation_id: operationId, status: "running" },
      })}\n\n`,
    ))
    await until(() => setup.captureCharFrame().includes("Veasel is working"))
    releaseOperations(Response.json([{
      id: operationId,
      session_id: "s1",
      status: "queued",
      provider: "",
      model: "",
      error: "",
      created_at: "2026-10-23T00:00:00Z",
      updated_at: "2026-10-23T00:00:00Z",
    }]))
    await Bun.sleep(20)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Veasel is working")
    expect(setup.captureCharFrame()).not.toContain("1 follow-up queued")
    setup.mockInput.pressKey("x", { ctrl: true })
    await until(() => cancellations.length === 1)
    expect(cancellations).toEqual([`/v1/sessions/s1/operations/${operationId}/cancel`])
  } finally {
    releaseOperations(Response.json([]))
    controller.abort()
    setup.renderer.destroy()
    server.stop(true)
  }
})
