/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { VeaselApiClient } from "../api-client"
import { LiveApp } from "./live-app"

test("LiveApp browses durable session executions and inspects a failed run", async () => {
  const controller = new AbortController()
  const requested: string[] = []
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch(request) {
    const url = new URL(request.url)
    const path = url.pathname
    requested.push(`${path}${url.search}`)
    if (path === "/v1/events") return new Response(new ReadableStream({ start(stream) {
      stream.enqueue(new TextEncoder().encode(": connected\n\n"))
    } }), { headers: { "content-type": "text/event-stream" } })
    if (path === "/v1/sessions") return Response.json([
      { id: "a", title: "Real project", directory: "/project/alpha" },
    ])
    if (path === "/v1/sessions/a/messages") return Response.json([])
    if (path === "/v1/operations") {
      if (url.searchParams.get("search") === "needle") return Response.json({ operations: [
        {
          session_title: "Needle project",
          operation: {
            id: "run-4", session_id: "d", status: "failed", provider: "openai", model: "gpt-test",
            error: "needle found in durable error", usage_reported: false,
            created_at: "2026-10-19 09:00:00", updated_at: "2026-10-19 09:00:30",
          },
        },
      ] })
      if (url.searchParams.has("before")) return Response.json({ operations: [
        {
          session_title: "Older project",
          operation: {
            id: "run-3", session_id: "c", status: "uncertain", provider: "gemini", model: "gemini-test",
            error: "server restarted during execution", usage_reported: false,
            created_at: "2026-10-20 09:00:00", updated_at: "2026-10-20 09:00:30",
          },
        },
      ] })
      return Response.json({ operations: [
        {
          session_title: "Beta project",
          operation: {
            id: "run-2", session_id: "b", status: "failed", provider: "anthropic", model: "claude-test",
            error: "provider timed out", usage_reported: false,
            created_at: "2026-10-21 11:00:00", updated_at: "2026-10-21 11:00:30",
          },
        },
        {
          session_title: "Alpha project",
          operation: {
            id: "run-1", session_id: "a", status: "completed", provider: "openai", model: "gpt-test",
            error: "", usage_reported: true, input_tokens: 20, output_tokens: 8,
            created_at: "2026-10-21 10:00:00", updated_at: "2026-10-21 10:00:02",
          },
        },
      ], next_before: "run-1" })
    }
    return Response.json({})
  } })
  const setup = await testRender(
    () => <LiveApp api={new VeaselApiClient(server.url.origin, controller.signal)} directory="/launch" />,
    { width: 100, height: 35, kittyKeyboard: true },
  )
  async function until(text: string) {
    for (let i = 0; i < 100; i++) {
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
    await setup.mockInput.typeText("/runs")
    setup.mockInput.pressEnter()
    await until("All executions · 2")
    expect(requested.some((item) => item.startsWith("/v1/operations?limit=50"))).toBe(true)
    expect(setup.captureCharFrame()).toContain("FAILED")
    expect(setup.captureCharFrame()).toContain("Beta project")
    setup.mockInput.pressArrow("down")
    setup.mockInput.pressArrow("down")
    setup.mockInput.pressEnter()
    await until("All executions · 3")
    expect(requested).toContain("/v1/operations?before=run-1&limit=50")
    expect(setup.captureCharFrame()).toContain("Older project")
    await setup.mockInput.typeText("needle")
    await until("All executions · 1")
    expect(requested.some((item) => item.includes("search=needle"))).toBe(true)
    expect(setup.captureCharFrame()).toContain("Needle project")
    setup.mockInput.pressEnter()
    await until("Execution details")
    expect(setup.captureCharFrame()).toContain("Session: Needle project")
    expect(setup.captureCharFrame()).toContain("needle found in durable error")
  } finally {
    setup.renderer.destroy()
    controller.abort()
    server.stop(true)
  }
})
