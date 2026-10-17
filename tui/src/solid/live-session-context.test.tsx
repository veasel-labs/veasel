/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { testRender } from "@opentui/solid"
import { LiveApp } from "./live-app"
import { VeaselApiClient } from "../api-client"
import { resolveAttachmentPath } from "./composer-attachments"

test("session tabs retain separate drafts and autocomplete from the selected project", async () => {
  const root = mkdtempSync(join(tmpdir(), "veasel-session-context-"))
  const alpha = join(root, "alpha")
  const beta = join(root, "beta")
  mkdirSync(alpha)
  mkdirSync(beta)
  writeFileSync(join(alpha, "alpha-only.v"), "module main")
  writeFileSync(join(beta, "beta-only.v"), "module main")
  writeFileSync(join(alpha, "alpha-attachment.txt"), "alpha content")
  const submissions: Array<{ session: string; content: string }> = []
  const controller = new AbortController()
  const server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    async fetch(request) {
      const path = new URL(request.url).pathname
      if (path === "/v1/events") return new Response(new ReadableStream({
        start(stream) { stream.enqueue(new TextEncoder().encode(": connected\n\n")) },
      }), { headers: { "content-type": "text/event-stream" } })
      if (path === "/v1/sessions") return Response.json([
        { id: "a", title: "Session alpha", directory: alpha },
        { id: "b", title: "Session beta", directory: beta },
      ])
      if (path.endsWith("/messages")) {
        if (request.method === "POST") {
          const body = await request.json() as { content: string }
          submissions.push({ session: path, content: body.content })
          return Response.json({
            operation_id: request.headers.get("x-veasel-operation-id"), status: "running",
          }, { status: 202 })
        }
        return Response.json([])
      }
      return Response.json({})
    },
  })
  const setup = await testRender(() => (
    <LiveApp api={new VeaselApiClient(server.url.origin, controller.signal)} directory={root} />
  ), { width: 100, height: 35, kittyKeyboard: true })
  async function until(text: string) {
    for (let n = 0; n < 100; n++) {
      await setup.renderOnce()
      if (setup.captureCharFrame().includes(text)) return
      await Bun.sleep(5)
    }
    throw new Error(`Missing visible text: ${text}`)
  }
  try {
    await until("Session alpha")
    setup.mockInput.pressEnter()
    await setup.renderOnce()
    await setup.mockInput.typeText("Draft for alpha")
    await setup.mockInput.pasteBracketedText("./alpha-attachment.txt")
    await setup.renderOnce()
    setup.mockInput.pressKey("]", { ctrl: true })
    await setup.renderOnce()
    expect(setup.captureCharFrame()).not.toContain("Draft for alpha")
    await setup.mockInput.typeText("Draft for beta")
    await setup.renderOnce()
    setup.mockInput.pressKey("[", { ctrl: true })
    await until("Draft for alpha")
    expect(setup.captureCharFrame()).not.toContain("Draft for beta")
    setup.mockInput.pressKey("u", { ctrl: true })
    await setup.mockInput.typeText("@")
    await until("alpha-only.v")
    expect(setup.captureCharFrame()).not.toContain("beta-only.v")
    setup.mockInput.pressKey("]", { ctrl: true })
    await until("Draft for beta")
    setup.mockInput.pressKey("u", { ctrl: true })
    await setup.mockInput.typeText("@")
    await until("beta-only.v")
    expect(setup.captureCharFrame()).not.toContain("alpha-only.v")
    setup.mockInput.pressKey("u", { ctrl: true })
    await setup.mockInput.typeText("Submit beta")
    await setup.mockInput.pasteBracketedText("./beta-only.v")
    await setup.renderOnce()
    setup.mockInput.pressEnter()
    for (let n = 0; n < 100 && submissions.length === 0; n++) await Bun.sleep(5)
    expect(submissions).toHaveLength(1)
    expect(submissions[0]!.session).toContain("/b/messages")
    expect(submissions[0]!.content).toContain(join(beta, "beta-only.v"))
    expect(submissions[0]!.content).not.toContain("alpha-attachment")
  } finally {
    controller.abort()
    setup.renderer.destroy()
    server.stop(true)
    rmSync(root, { recursive: true, force: true })
  }
})

test("relative attachment paths resolve inside the selected workspace", () => {
  let checked = ""
  const workspace = join(tmpdir(), "project-b")
  const expected = join(workspace, "src", "main.v")
  expect(resolveAttachmentPath("./src/main.v", {
    cwd: workspace,
    exists: (path) => { checked = path; return true },
  })).toBe(expected)
  expect(checked).toBe(expected)
})
