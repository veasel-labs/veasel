/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { VeaselApiClient } from "../api-client"
import { LiveApp } from "./live-app"

test("LiveApp completes a pending review ID and opens that inspected review", async () => {
  const controller = new AbortController()
  const requests: string[] = []
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch(request) {
    const path = new URL(request.url).pathname
    requests.push(`${request.method} ${path}`)
    if (path === "/v1/events") return new Response(new ReadableStream({ start(stream) {
      stream.enqueue(new TextEncoder().encode(": connected\n\n"))
    } }), { headers: { "content-type": "text/event-stream" } })
    if (path === "/v1/sessions") return Response.json([{ id: "a", title: "Real project", directory: "/project/alpha" }])
    if (path === "/v1/sessions/a/messages") return Response.json([])
    if (path === "/v1/sessions/a/workspace/edits") return Response.json([
      { id: "edit-123", path: "src/target.v", status: "pending" },
      { id: "edit-456", path: "src/other.v", status: "pending" },
    ])
    if (path.endsWith("/workspace/commands") || path.endsWith("/mcp-tool-calls")) return Response.json([])
    if (path === "/v1/sessions/a/workspace/edits/edit-123") {
      return Response.json({ id: "edit-123", path: "src/target.v", status: "pending", diff: "@@ -1 +1 @@\n-old\n+target-change" })
    }
    if (path === "/v1/sessions/a/workspace/edits/edit-456") {
      return Response.json({ id: "edit-456", path: "src/other.v", status: "pending", diff: "@@ -1 +1 @@\n-old\n+other-change" })
    }
    return Response.json({})
  } })
  const setup = await testRender(
    () => <LiveApp api={new VeaselApiClient(server.url.origin, controller.signal)} directory="/launch" />,
    { width: 100, height: 35, kittyKeyboard: true },
  )
  async function until(text: string) {
    for (let n = 0; n < 100; n++) {
      await setup.renderOnce()
      if (setup.captureCharFrame().includes(text)) return
      await Bun.sleep(5)
    }
    throw new Error(`Missing ${text}\n${setup.captureCharFrame()}`)
  }
  try {
    await until("Real project")
    setup.mockInput.pressEnter()
    await setup.renderOnce()
    await setup.mockInput.typeText("/patch show ")
    await until("edit-123")
    expect(setup.captureCharFrame()).toContain("src/target.v")
    expect(requests).not.toContain("GET /v1/sessions/a/workspace/edits/edit-123")
    setup.mockInput.pressTab()
    await setup.renderOnce()
    expect(setup.renderer.currentFocusedEditor?.plainText).toBe("/patch show edit-123")
    setup.mockInput.pressEnter()
    await until("target-change")
    expect(requests).toContain("GET /v1/sessions/a/workspace/edits/edit-123")
    expect(requests).not.toContain("GET /v1/sessions/a/workspace/edits/edit-456")
    expect(requests.some((item) => item.startsWith("POST "))).toBe(false)
  } finally {
    setup.renderer.destroy()
    controller.abort()
    server.stop(true)
  }
})
