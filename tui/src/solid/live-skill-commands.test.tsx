/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { VeaselApiClient } from "../api-client"
import { LiveApp } from "./live-app"

test("LiveApp routes Skill enable, disable, and one-shot invoke to the session API", async () => {
  const controller = new AbortController()
  const calls: Array<{ path: string; body?: unknown }> = []
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
    const url = new URL(request.url)
    if (url.pathname === "/v1/events") return new Response(new ReadableStream({ start(stream) {
      stream.enqueue(new TextEncoder().encode(": connected\n\n"))
    } }), { headers: { "content-type": "text/event-stream" } })
    if (url.pathname === "/v1/sessions") return Response.json([{ id: "a", title: "Real project", directory: "/project/alpha" }])
    if (url.pathname === "/v1/sessions/a/messages") return Response.json([])
    if (url.pathname === "/v1/sessions/a/skills" || url.pathname === "/v1/sessions/a/skills/invoke") {
      const body = request.method === "POST" ? await request.json() : undefined
      calls.push({ path: url.pathname, body })
      return Response.json(url.pathname.endsWith("/invoke")
        ? { plugin_name: "local-kit", skill_name: "review", pending: [{ plugin_name: "local-kit", skill_name: "review" }] }
        : [{ plugin_name: "local-kit", skill_name: "review" }])
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
    throw new Error(`Missing ${text}`)
  }
  async function submit(text: string, confirmation: string) {
    await setup.mockInput.typeText(text)
    setup.mockInput.pressEnter()
    await until(confirmation)
  }
  try {
    await until("Real project")
    setup.mockInput.pressEnter()
    await setup.renderOnce()
    await submit("/skill on local-kit/review", "Enabled local-kit/review")
    await submit("/skill off local-kit/review", "Disabled local-kit/review")
    await submit("/skill run local-kit/review", "Queued local-kit/review")
    expect(calls).toEqual([
      { path: "/v1/sessions/a/skills", body: { plugin_name: "local-kit", skill_name: "review", enabled: true } },
      { path: "/v1/sessions/a/skills", body: { plugin_name: "local-kit", skill_name: "review", enabled: false } },
      { path: "/v1/sessions/a/skills/invoke", body: { plugin_name: "local-kit", skill_name: "review" } },
    ])
  } finally {
    setup.renderer.destroy()
    controller.abort()
    server.stop(true)
  }
})

test("LiveApp loads real Skills for slash-command argument completion", async () => {
  const controller = new AbortController()
  const directories: string[] = []
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch(request) {
    const url = new URL(request.url)
    if (url.pathname === "/v1/events") return new Response(new ReadableStream({ start(stream) {
      stream.enqueue(new TextEncoder().encode(": connected\n\n"))
    } }), { headers: { "content-type": "text/event-stream" } })
    if (url.pathname === "/v1/sessions") return Response.json([{ id: "a", title: "Real project", directory: "/project/alpha" }])
    if (url.pathname === "/v1/plugins") {
      directories.push(url.searchParams.get("directory") ?? "")
      return Response.json({ plugins: [{ name: "local-kit", skills: [{ name: "review", description: "Review the actual workspace" }] }] })
    }
    if (url.pathname.endsWith("/messages")) return Response.json([])
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
    throw new Error(`Missing ${text}`)
  }
  try {
    await until("Real project")
    setup.mockInput.pressEnter()
    await setup.renderOnce()
    await setup.mockInput.typeText("/skill on ")
    await until("local-kit/review")
    expect(directories).toEqual(["/project/alpha"])
    setup.mockInput.pressTab()
    await setup.renderOnce()
    expect(setup.renderer.currentFocusedEditor?.plainText).toBe("/skill on local-kit/review")
  } finally {
    setup.renderer.destroy()
    controller.abort()
    server.stop(true)
  }
})
