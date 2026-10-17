/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { onMount } from "solid-js"
import { testRender } from "@opentui/solid"
import { VeaselApiClient } from "../api-client"
import { loadPendingSolidReviews, inspectSolidReview, decideSolidReviews } from "./reviews-inventory"
import { DialogProvider, useDialog } from "./ui/dialog"
import { openReviewPanel, type ReviewPanelProps } from "./component/review-panel"

function Harness(props: ReviewPanelProps) {
  const dialog = useDialog()
  onMount(() => openReviewPanel(dialog, props))
  return <text>Workspace</text>
}

for (const failFirst of [false, true]) {
  test(`review inventory does not inspect unseen items; ${failFirst ? "detail retry" : "batch approval"}`, async () => {
    const requests: string[] = []
    let failDetail = failFirst
    const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch(request) {
      const path = new URL(request.url).pathname
      requests.push(`${request.method} ${path}`)
      if (path.endsWith("/edits")) return Response.json([
        { id: "e1", path: "first.v", status: "pending" },
        { id: "e2", path: "second.v", status: "pending" },
      ])
      if (path.endsWith("/commands") || path.endsWith("/mcp-tool-calls")) return Response.json([])
      if (path.endsWith("/approve")) return Response.json({ status: "applied" })
      if (failDetail) return new Response("details unavailable", { status: 503 })
      const id = path.split("/").at(-1)!
      return Response.json({ id, path: id === "e1" ? "first.v" : "second.v", status: "pending", diff: `+detail-${id}` })
    } })
    const api = new VeaselApiClient(server.url.origin)
    let setup: Awaited<ReturnType<typeof testRender>> | undefined
    try {
      const reviews = await loadPendingSolidReviews(api, "session")
      expect(requests).toHaveLength(3)
      expect(reviews.every((item) => item.inspected === false)).toBe(true)
      setup = await testRender(() => <DialogProvider><Harness
        reviews={reviews}
        onInspect={(target) => inspectSolidReview(api, "session", target)}
        onDecide={(decision, targets) => decideSolidReviews(api, "session", decision, targets)}
      /></DialogProvider>, { width: 100, height: 35, kittyKeyboard: true })
      async function until(text: string) {
        for (let n = 0; n < 100; n++) {
          await setup!.renderOnce()
          if (setup!.captureCharFrame().includes(text)) return
          await Bun.sleep(5)
        }
        throw new Error(`Missing ${text}`)
      }
      if (failFirst) {
        await until("r retry")
        setup.mockInput.pressKey("a")
        await setup.renderOnce()
        expect(requests.some((request) => request.startsWith("POST"))).toBe(false)
        failDetail = false
        setup.mockInput.pressKey("r")
      }
      await until("detail-e1")
      expect(requests.some((request) => request.endsWith("/e2"))).toBe(false)
      setup.mockInput.pressKey("a", { shift: true })
      await until("inspect every selected item")
      expect(requests.some((request) => request.startsWith("POST"))).toBe(false)
      setup.mockInput.pressKey("n")
      await until("detail-e2")
      setup.mockInput.pressKey("a", { shift: true })
      for (let n = 0; n < 100 && requests.filter((request) => request.startsWith("POST")).length < 2; n++) await Bun.sleep(5)
      expect(requests.filter((request) => request.startsWith("POST"))).toHaveLength(2)
    } finally { setup?.renderer.destroy(); server.stop(true) }
  })
}

test("late detail response cannot mark a review inspected after navigating away", async () => {
  const reviews = ["first", "second"].map((id) => ({
    kind: "patch" as const, id, path: `${id}.v`, diff: "", pending: true, inspected: false,
  }))
  let resolveFirst!: (item: typeof reviews[number]) => void
  const firstDetail = new Promise<typeof reviews[number]>((resolve) => { resolveFirst = resolve })
  let firstRequests = 0
  let decisions = 0
  const setup = await testRender(() => <DialogProvider><Harness
    reviews={reviews}
    onInspect={async (target) => {
      if (target.id === "first" && ++firstRequests === 1) return await firstDetail
      return { ...reviews.find((item) => item.id === target.id)!, diff: `+visible-${target.id}` }
    }}
    onDecide={(_decision, targets) => { decisions++; return { settled: targets, failed: [] } }}
  /></DialogProvider>, { width: 100, height: 35, kittyKeyboard: true })
  try {
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Loading review details")
    setup.mockInput.pressKey("n")
    await setup.renderOnce()
    await setup.renderOnce()
    resolveFirst({ ...reviews[0]!, diff: "+late-first" })
    await Bun.sleep(5)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("visible-second")
    expect(setup.captureCharFrame()).not.toContain("late-first")
    setup.mockInput.pressKey("a", { shift: true })
    await setup.renderOnce()
    expect(decisions).toBe(0)
    setup.mockInput.pressKey("p")
    await Bun.sleep(5)
    await setup.renderOnce()
    expect(firstRequests).toBe(2)
    expect(setup.captureCharFrame()).toContain("visible-first")
  } finally {
    resolveFirst(reviews[0]!)
    setup.renderer.destroy()
  }
})
