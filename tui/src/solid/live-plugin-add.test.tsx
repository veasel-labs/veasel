/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { VeaselApiClient } from "../api-client"
import { LiveApp } from "./live-app"

test("LiveApp adds a local plugin through API validation and confirms replacement", async () => {
  const controller = new AbortController()
  const requests: Array<{ path: string; replace: boolean }> = []
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
    const url = new URL(request.url)
    if (url.pathname === "/v1/events") return new Response(new ReadableStream({ start(stream) {
      stream.enqueue(new TextEncoder().encode(": connected\n\n"))
    } }), { headers: { "content-type": "text/event-stream" } })
    if (url.pathname === "/v1/sessions") return Response.json([{ id: "a", title: "Real project", directory: "/project/alpha" }])
    if (url.pathname.endsWith("/messages")) return Response.json([])
    if (url.pathname === "/v1/plugins/links" && request.method === "POST") {
      const body = await request.json() as { path: string; replace: boolean }
      requests.push(body)
      return Response.json({ name: "review-tools", path: body.path, version: "1.0.0" })
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
    await setup.mockInput.typeText("/plugin add")
    setup.mockInput.pressEnter()
    await until("Add local Agent Plugin")
    await setup.mockInput.typeText("/tmp/review-tools")
    setup.mockInput.pressEnter()
    await until("Linked plugin · review-tools")
    expect(requests).toEqual([{ path: "/tmp/review-tools", replace: false }])

    await setup.mockInput.typeText("/plugin add --replace /tmp/replacement")
    setup.mockInput.pressEnter()
    await until("Replace plugin link?")
    expect(requests).toHaveLength(1)
    setup.mockInput.pressEnter()
    await until("Linked plugin · review-tools")
    expect(requests).toEqual([
      { path: "/tmp/review-tools", replace: false },
      { path: "/tmp/replacement", replace: true },
    ])
  } finally {
    setup.renderer.destroy()
    controller.abort()
    server.stop(true)
  }
})
