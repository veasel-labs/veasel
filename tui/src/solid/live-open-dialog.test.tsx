/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { LiveApp } from "./live-app"
import { VeaselApiClient } from "../api-client"

test("first-run Open shows no demo projects and creates a real session", async () => {
  const controller = new AbortController()
  const created: Array<{ title: string; directory: string }> = []
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
    const path = new URL(request.url).pathname
    if (path === "/v1/events") return new Response(new ReadableStream({ start(stream) {
      stream.enqueue(new TextEncoder().encode(": connected\n\n"))
    } }), { headers: { "content-type": "text/event-stream" } })
    if (path === "/v1/sessions") {
      if (request.method === "POST") {
        const body = await request.json() as { title: string; directory: string }
        created.push(body)
        return Response.json({ id: "new-session", ...body })
      }
      return Response.json(created.map((body) => ({ id: "new-session", ...body })))
    }
    if (path.endsWith("/messages")) return Response.json([])
    return Response.json({})
  } })
  const setup = await testRender(() => <LiveApp api={new VeaselApiClient(server.url.origin, controller.signal)} directory="/real/workspace" />, { width: 100, height: 35, kittyKeyboard: true })
  async function until(text: string) {
    for (let i = 0; i < 100; i++) {
      await setup.renderOnce()
      if (setup.captureCharFrame().includes(text)) return
      await Bun.sleep(5)
    }
    throw new Error(`Missing ${text}`)
  }
  try {
    await setup.renderOnce()
    await Bun.sleep(20)
    setup.mockInput.pressKey("o", { ctrl: true })
    await until("New session in this project")
    const frame = setup.captureCharFrame()
    expect(frame).not.toContain("~/veasel")
    expect(frame).not.toContain("~/.ai-workspace")
    expect(frame).toContain("/real/workspace")
    setup.mockInput.pressEnter()
    await until("New session")
    for (let i = 0; i < 100 && created.length === 0; i++) await Bun.sleep(5)
    expect(created).toEqual([{ title: "New session", directory: "/real/workspace" }])
  } finally { setup.renderer.destroy(); controller.abort(); server.stop(true) }
})
