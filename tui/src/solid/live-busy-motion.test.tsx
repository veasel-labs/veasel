/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { VeaselApiClient } from "../api-client"
import { busyGlyphFrames, busyGlyphReduced } from "../reduced-motion"
import { LiveApp } from "./live-app"

// The busy status must cycle its glyph while work is in flight (parity
// with the classic shell) and stay perfectly still under reduced
// motion. The mock backend never answers the session list, so the
// startup "connecting" busy status stays on screen for sampling.

function serveHanging() {
  return Bun.serve({
    port: 0,
    fetch(req) {
      const url = new URL(req.url)
      if (url.pathname === "/v1/health") return Response.json({ healthy: true })
      if (url.pathname === "/v1/events") return new Response(new ReadableStream({ start() {} }), { headers: { "content-type": "text/event-stream" } })
      return new Promise<Response>(() => {})
    },
  })
}

function busyGlyphs(frame: string): string[] {
  const glyphs: string[] = []
  for (const line of frame.split("\n")) {
    const match = line.match(/([◌◍○]) busy/)
    if (match) glyphs.push(match[1]!)
  }
  return glyphs
}

test("busy status glyph cycles while connecting when motion is allowed", async () => {
  const server = serveHanging()
  const previous = process.env["VEASEL_TUI_REDUCED_MOTION"]
  process.env["VEASEL_TUI_REDUCED_MOTION"] = "0"
  try {
    const setup = await testRender(
      () => <LiveApp api={new VeaselApiClient(`http://127.0.0.1:${server.port}`, new AbortController().signal)} directory="/project" />,
      { width: 80, height: 24 },
    )
    try {
      await setup.waitFor(() => setup.captureCharFrame().includes("busy"))
      const seen = new Set<string>()
      for (let sample = 0; sample < 12 && seen.size < 2; sample++) {
        await Bun.sleep(220)
        await setup.renderOnce().catch(() => undefined)
        for (const glyph of busyGlyphs(await setup.captureCharFrame())) seen.add(glyph)
      }
      expect(seen.size).toBeGreaterThanOrEqual(2)
      for (const glyph of seen) expect(busyGlyphFrames as unknown as string[]).toContain(glyph)
    } finally {
      setup.renderer.destroy()
    }
  } finally {
    if (previous === undefined) delete process.env["VEASEL_TUI_REDUCED_MOTION"]
    else process.env["VEASEL_TUI_REDUCED_MOTION"] = previous
    server.stop(true)
  }
}, 30000)

test("busy status glyph stays static under reduced motion", async () => {
  const server = serveHanging()
  const previous = process.env["VEASEL_TUI_REDUCED_MOTION"]
  process.env["VEASEL_TUI_REDUCED_MOTION"] = "1"
  try {
    const setup = await testRender(
      () => <LiveApp api={new VeaselApiClient(`http://127.0.0.1:${server.port}`, new AbortController().signal)} directory="/project" />,
      { width: 80, height: 24 },
    )
    try {
      await setup.waitFor(() => setup.captureCharFrame().includes("busy"))
      const seen = new Set<string>()
      for (let sample = 0; sample < 6; sample++) {
        await Bun.sleep(220)
        await setup.renderOnce().catch(() => undefined)
        for (const glyph of busyGlyphs(await setup.captureCharFrame())) seen.add(glyph)
      }
      expect([...seen]).toEqual([busyGlyphReduced])
    } finally {
      setup.renderer.destroy()
    }
  } finally {
    if (previous === undefined) delete process.env["VEASEL_TUI_REDUCED_MOTION"]
    else process.env["VEASEL_TUI_REDUCED_MOTION"] = previous
    server.stop(true)
  }
}, 30000)
