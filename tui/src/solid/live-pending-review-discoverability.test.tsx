/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { VeaselApiClient } from "../api-client"
import { LiveApp } from "./live-app"

function reviewServer() {
  const requests: string[] = []
  let pending = false
  let inventoryUnavailable = false
  let eventStream: ReadableStreamDefaultController<Uint8Array> | undefined
  let submittedOperationId = ""
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request) {
      const path = new URL(request.url).pathname
      requests.push(`${request.method} ${path}`)
      if (path === "/v1/events") return new Response(new ReadableStream({
        start(stream) {
          eventStream = stream
          stream.enqueue(new TextEncoder().encode(": connected\n\n"))
        },
      }), { headers: { "content-type": "text/event-stream" } })
      if (path === "/v1/sessions") return Response.json([
        { id: "session-1", title: "HTML request", directory: "/tmp" },
      ])
      if (path === "/v1/sessions/session-1/messages") {
        if (request.method === "POST") {
          pending = true
          submittedOperationId = request.headers.get("x-veasel-operation-id") ?? ""
          return Response.json({ operation_id: submittedOperationId, status: "running" }, { status: 202 })
        }
        return Response.json([])
      }
      if (path === "/v1/sessions/session-1/operations") return Response.json([])
      if (path === "/v1/sessions/session-1/workspace/edits") return Response.json([])
      if (path === "/v1/sessions/session-1/workspace/commands") {
        if (inventoryUnavailable) return new Response("temporarily unavailable", { status: 503 })
        return Response.json(pending ? [{
          id: "command-1",
          command: "printf '<html>Veasel</html>' > /tmp/veasel-code.html",
          cwd: "/tmp",
          timeout_seconds: 30,
          status: "pending",
        }] : [])
      }
      if (path === "/v1/sessions/session-1/mcp-tool-calls") return Response.json([])
      if (path === "/v1/sessions/session-1/workspace/commands/command-1") {
        return Response.json({
          id: "command-1",
          command: "printf '<html>Veasel</html>' > /tmp/veasel-code.html",
          cwd: "/tmp",
          timeout_seconds: 30,
          status: "pending",
        })
      }
      if (path === "/v1/sessions/session-1/workspace/commands/command-1/approve") {
        pending = false
        return Response.json({
          id: "command-1",
          command: "printf '<html>Veasel</html>' > /tmp/veasel-code.html",
          cwd: "/tmp",
          timeout_seconds: 30,
          status: "succeeded",
          exit_code: 0,
          output: "wrote /tmp/veasel-code.html",
        })
      }
      return Response.json({})
    },
  })
  return {
    server,
    requests,
    setInventoryUnavailable(value: boolean) { inventoryUnavailable = value },
    completeTurn() {
      if (!eventStream || !submittedOperationId) throw new Error("Turn was not submitted")
      eventStream.enqueue(new TextEncoder().encode(`event: session.turn_completed\ndata: ${JSON.stringify({
        session_id: "session-1",
        data: { operation_id: submittedOperationId, status: "completed" },
      })}\n\n`))
    },
  }
}

async function until(
  setup: Awaited<ReturnType<typeof testRender>>,
  text: string,
) {
  for (let attempt = 0; attempt < 120; attempt++) {
    await setup.renderOnce()
    if (setup.captureCharFrame().includes(text)) return
    await Bun.sleep(5)
  }
  throw new Error(`Missing ${text}\n${setup.captureCharFrame()}`)
}

test("LiveApp exposes pending shell reviews and approves only through the review panel", async () => {
  const controller = new AbortController()
  const { server, requests, completeTurn, setInventoryUnavailable } = reviewServer()
  const setup = await testRender(
    () => <LiveApp api={new VeaselApiClient(server.url.origin, controller.signal)} directory="/tmp" />,
    { width: 100, height: 35, kittyKeyboard: true },
  )
  try {
    await until(setup, "HTML request")
    setup.mockInput.pressEnter()
    await until(setup, "Message Veasel")
    await setup.mockInput.typeText("Create the requested HTML file")
    setup.mockInput.pressEnter()
    for (let attempt = 0; attempt < 120 && !requests.includes("POST /v1/sessions/session-1/messages"); attempt++) {
      await Bun.sleep(5)
    }
    expect(requests).toContain("POST /v1/sessions/session-1/messages")
    completeTurn()
    await until(setup, "1 pending · Ctrl+R")
    expect(setup.captureCharFrame()).toContain("Ctrl+R reviews")

    // A failed refresh after known pending work must not erase the cue.
    setInventoryUnavailable(true)
    await setup.mockInput.typeText("Follow up while the approval is pending")
    setup.mockInput.pressEnter()
    for (let attempt = 0; attempt < 120 && requests.filter((request) => request === "POST /v1/sessions/session-1/messages").length < 2; attempt++) {
      await Bun.sleep(5)
    }
    completeTurn()
    await until(setup, "1 pending · Ctrl+R · refresh failed")
    setInventoryUnavailable(false)

    setup.mockInput.pressKey("r", { ctrl: true })
    await until(setup, "Shell command")
    await until(setup, "/tmp/veasel-code.html")
    expect(setup.captureCharFrame()).toContain("a approve")
    expect(requests).not.toContain("POST /v1/sessions/session-1/workspace/commands/command-1/approve")

    setup.mockInput.pressKey("a")
    for (let attempt = 0; attempt < 120 && !requests.includes("POST /v1/sessions/session-1/workspace/commands/command-1/approve"); attempt++) {
      await Bun.sleep(5)
    }
    expect(requests).toContain("POST /v1/sessions/session-1/workspace/commands/command-1/approve")
    let settledHeader = ""
    for (let attempt = 0; attempt < 120; attempt++) {
      await setup.renderOnce()
      settledHeader = setup.captureCharFrame().split("\n").find((line) => line.includes("VEASEL / CODE")) ?? ""
      if (settledHeader.includes("connected") && !settledHeader.includes("pending")) break
      await Bun.sleep(5)
    }
    expect(settledHeader).toContain("connected")
    expect(settledHeader).not.toContain("pending")
  } finally {
    setup.renderer.destroy()
    controller.abort()
    server.stop(true)
  }
})

test("compact LiveApp keeps the review shortcut discoverable beside pending work", async () => {
  const controller = new AbortController()
  const { server, requests, completeTurn } = reviewServer()
  const setup = await testRender(
    () => <LiveApp api={new VeaselApiClient(server.url.origin, controller.signal)} directory="/tmp" />,
    { width: 32, height: 12, kittyKeyboard: true },
  )
  try {
    await until(setup, "HTML request")
    setup.mockInput.pressEnter()
    await until(setup, "Message Veasel")
    await setup.mockInput.typeText("Create the requested HTML file")
    setup.mockInput.pressEnter()
    for (let attempt = 0; attempt < 120 && !requests.includes("POST /v1/sessions/session-1/messages"); attempt++) {
      await Bun.sleep(5)
    }
    expect(requests).toContain("POST /v1/sessions/session-1/messages")
    completeTurn()
    await until(setup, "pending")
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Ctrl+R reviews")
    const statusLine = frame.split("\n").find((line) => line.includes("VEASEL / CODE"))
    expect(statusLine).toContain("▲ 1 pending")
  } finally {
    setup.renderer.destroy()
    controller.abort()
    server.stop(true)
  }
})

test("a background turn completion cannot invalidate the focused session review refresh", async () => {
  const controller = new AbortController()
  const requests: string[] = []
  let operationId = ""
  let aMessageReads = 0
  let eventStream: ReadableStreamDefaultController<Uint8Array> | undefined
  let signalBInventoryStarted!: () => void
  const bInventoryStarted = new Promise<void>((resolve) => { signalBInventoryStarted = resolve })
  let releaseBInventory!: () => void
  const bInventoryGate = new Promise<void>((resolve) => { releaseBInventory = resolve })
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const path = new URL(request.url).pathname
      requests.push(`${request.method} ${path}`)
      if (path === "/v1/events") return new Response(new ReadableStream({
        start(stream) {
          eventStream = stream
          stream.enqueue(new TextEncoder().encode(": connected\n\n"))
        },
      }), { headers: { "content-type": "text/event-stream" } })
      if (path === "/v1/sessions") return Response.json([
        { id: "a", title: "Session A", directory: "/tmp/a" },
        { id: "b", title: "Session B", directory: "/tmp/b" },
      ])
      if (path === "/v1/sessions/a/messages" || path === "/v1/sessions/b/messages") {
        if (request.method === "POST") {
          operationId = request.headers.get("x-veasel-operation-id") ?? ""
          return Response.json({ operation_id: operationId, status: "running" }, { status: 202 })
        }
        if (path === "/v1/sessions/a/messages") aMessageReads++
        return Response.json([])
      }
      if (path === "/v1/sessions/a/operations" || path === "/v1/sessions/b/operations") return Response.json([])
      if (path.endsWith("/workspace/edits")) return Response.json([])
      if (path === "/v1/sessions/a/workspace/commands") return Response.json([])
      if (path === "/v1/sessions/b/workspace/commands") {
        signalBInventoryStarted()
        await bInventoryGate
        return Response.json([{
          id: "b-command",
          command: "printf B > /tmp/b-result.html",
          cwd: "/tmp/b",
          timeout_seconds: 30,
          status: "pending",
        }])
      }
      if (path.endsWith("/mcp-tool-calls")) return Response.json([])
      return Response.json({})
    },
  })
  const setup = await testRender(
    () => <LiveApp api={new VeaselApiClient(server.url.origin, controller.signal)} directory="/tmp" />,
    { width: 100, height: 35, kittyKeyboard: true },
  )
  try {
    await until(setup, "Session A")
    setup.mockInput.pressEnter()
    await until(setup, "Message Veasel")
    await setup.mockInput.typeText("Work in session A")
    setup.mockInput.pressEnter()
    for (let attempt = 0; attempt < 120 && !operationId; attempt++) await Bun.sleep(5)
    expect(operationId).not.toBe("")

    setup.mockInput.pressKey("]", { ctrl: true })
    await until(setup, "Session B")
    await bInventoryStarted
    eventStream!.enqueue(new TextEncoder().encode(`event: session.turn_completed\ndata: ${JSON.stringify({
      session_id: "a",
      data: { operation_id: operationId, status: "completed" },
    })}\n\n`))
    for (let attempt = 0; attempt < 120 && aMessageReads < 2; attempt++) await Bun.sleep(5)
    expect(aMessageReads).toBeGreaterThanOrEqual(2)
    releaseBInventory()
    await until(setup, "1 pending · Ctrl+R")
    expect(setup.captureCharFrame()).toContain("Session B")
  } finally {
    releaseBInventory()
    setup.renderer.destroy()
    controller.abort()
    server.stop(true)
  }
})
