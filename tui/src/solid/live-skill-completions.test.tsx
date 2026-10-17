/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { LiveApp } from "./live-app"
import { SolidComposer } from "./composer"
import { VeaselApiClient } from "../api-client"

test("a composer without a catalog never suggests demo Skills", async () => {
  const setup = await testRender(() => <SolidComposer focused={true} />, { width: 80, height: 20 })
  try {
    await setup.renderOnce()
    await setup.mockInput.typeText("$")
    await setup.renderOnce()
    expect(setup.captureCharFrame()).not.toContain("$veasel/")
    expect(setup.captureCharFrame()).not.toContain("$demo/")
    expect(setup.captureCharFrame()).not.toContain("skills  ·")
  } finally { setup.renderer.destroy() }
})

for (const fail of [false, true]) {
  test(`live Skills discovery uses session project and ${fail ? "shows failure with retry" : "inserts a real completion"}`, async () => {
    const controller = new AbortController()
    const directories: string[] = []
    let failRequest = fail
    const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch(request) {
      const url = new URL(request.url)
      if (url.pathname === "/v1/events") return new Response(new ReadableStream({ start(stream) {
        stream.enqueue(new TextEncoder().encode(": connected\n\n"))
      } }), { headers: { "content-type": "text/event-stream" } })
      if (url.pathname === "/v1/sessions") return Response.json([{ id: "a", title: "Real project", directory: "/project/alpha" }])
      if (url.pathname === "/v1/plugins") {
        directories.push(url.searchParams.get("directory") ?? "")
        if (failRequest) return new Response("discovery failed", { status: 503 })
        return Response.json({ plugins: [{ name: "local-kit", skills: [{ name: "review", description: "Review the actual workspace" }] }] })
      }
      if (url.pathname.endsWith("/messages")) return Response.json([])
      return Response.json({})
    } })
    const setup = await testRender(() => <LiveApp api={new VeaselApiClient(server.url.origin, controller.signal)} directory="/launch" />, { width: 100, height: 35, kittyKeyboard: true })
    async function until(text: string) {
      for (let n = 0; n < 100; n++) {
        await setup.renderOnce()
        if (setup.captureCharFrame().includes(text)) return
        await Bun.sleep(5)
      }
      throw new Error(`Missing ${text}`)
    }
    try {
      await until("Real project")
      setup.mockInput.pressEnter()
      await setup.renderOnce()
      await setup.mockInput.typeText("$")
      if (fail) {
        await until("Skills unavailable")
        expect(setup.captureCharFrame()).not.toContain("$local-kit/review")
        failRequest = false
        setup.mockInput.pressBackspace()
        await setup.renderOnce()
        await setup.mockInput.typeText("$")
      }
      await until("$local-kit/review")
      expect(directories.every((directory) => directory === "/project/alpha")).toBe(true)
      expect(directories).toHaveLength(fail ? 2 : 1)
      setup.mockInput.pressTab()
      await setup.renderOnce()
      expect(setup.renderer.currentFocusedEditor?.plainText).toContain("$local-kit/review")
    } finally { setup.renderer.destroy(); controller.abort(); server.stop(true) }
  })
}
