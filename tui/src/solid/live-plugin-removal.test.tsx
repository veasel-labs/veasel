/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { VeaselApiClient } from "../api-client"
import { LiveApp } from "./live-app"

test("LiveApp completes plugin links and removes one only after confirmation", async () => {
  const controller = new AbortController()
  let linked = true
  let deleteCount = 0
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch(request) {
    const url = new URL(request.url)
    if (url.pathname === "/v1/events") return new Response(new ReadableStream({ start(stream) {
      stream.enqueue(new TextEncoder().encode(": connected\n\n"))
    } }), { headers: { "content-type": "text/event-stream" } })
    if (url.pathname === "/v1/sessions") return Response.json([{ id: "a", title: "Real project", directory: "/project/alpha" }])
    if (url.pathname.endsWith("/messages")) return Response.json([])
    if (url.pathname === "/v1/plugins/links" && request.method === "GET") {
      return Response.json({ links: linked ? [{ name: "review-tools", path: "/plugins/review-tools", display_name: "Review Tools" }] : [] })
    }
    if (url.pathname === "/v1/plugins/links/review-tools" && request.method === "DELETE") {
      deleteCount++
      linked = false
      return new Response(null, { status: 204 })
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
    await setup.mockInput.typeText("/plugin remove ")
    await until("review-tools")
    expect(setup.captureCharFrame()).toContain("/plugins/review-tools")
    setup.mockInput.pressTab()
    await setup.renderOnce()
    expect(setup.renderer.currentFocusedEditor?.plainText).toBe("/plugin remove review-tools")
    setup.mockInput.pressEnter()
    await until("Remove plugin link?")
    expect(deleteCount).toBe(0)
    expect(setup.captureCharFrame()).toContain("package files remain untouched")
    setup.mockInput.pressEscape()
    await setup.renderOnce()
    expect(deleteCount).toBe(0)
    await setup.mockInput.typeText("/plugin remove ")
    await until("review-tools")
    setup.mockInput.pressTab()
    await setup.renderOnce()
    setup.mockInput.pressEnter()
    await until("Remove plugin link?")
    setup.mockInput.pressEnter()
    await until("Removed plugin link · review-tools")
    expect(deleteCount).toBe(1)
    expect(linked).toBe(false)
  } finally {
    setup.renderer.destroy()
    controller.abort()
    server.stop(true)
  }
})
