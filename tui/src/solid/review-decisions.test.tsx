/** @jsxImportSource @opentui/solid */
import { afterEach, expect, test } from "bun:test"
import { onMount } from "solid-js"
import { testRender } from "@opentui/solid"
import { VeaselApiClient } from "../api-client"
import { decideSolidReviews } from "./reviews-inventory"
import { demoPendingReviews, type ReviewDecisionResult } from "./reviews"
import { DialogProvider, useDialog } from "./ui/dialog"
import { openReviewPanel, type ReviewPanelProps } from "./component/review-panel"

const setups: Array<Awaited<ReturnType<typeof testRender>>> = []
afterEach(() => { for (const setup of setups.splice(0)) setup.renderer.destroy() })
const size = { width: 80, height: 30, kittyKeyboard: true } as const

function Harness(props: {
  onDecide: ReviewPanelProps["onDecide"]
  onReady?: (dialog: ReturnType<typeof useDialog>) => void
}) {
  const dialog = useDialog()
  onMount(() => {
    props.onReady?.(dialog)
    openReviewPanel(dialog, { reviews: demoPendingReviews(), onDecide: props.onDecide })
  })
  return <text>Review test</text>
}

test("failed HTTP decisions remain visible and pending requests cannot be duplicated", async () => {
  let release!: () => void
  const gate = new Promise<void>((resolve) => { release = resolve })
  const requests: string[] = []
  let received!: () => void
  const receipt = new Promise<void>((resolve) => { received = resolve })
  let completed!: () => void
  const completion = new Promise<void>((resolve) => { completed = resolve })
  const server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    async fetch(request) {
      requests.push(request.method + " " + new URL(request.url).pathname)
      received()
      await gate
      return new Response("approval unavailable", { status: 503 })
    },
  })
  try {
    const api = new VeaselApiClient(server.url.origin)
    const setup = await testRender(() => (
      <DialogProvider>
        <Harness onDecide={async (decision, targets) => {
          const result = await decideSolidReviews(api, "session", decision, targets)
          completed()
          return result
        }} />
      </DialogProvider>
    ), size)
    setups.push(setup)
    await setup.renderOnce()
    setup.mockInput.pressKey("a")
    await receipt
    await setup.renderOnce()
    setup.mockInput.pressKey("a")
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Waiting for server")
    release()
    await completion
    await setup.renderOnce()
    expect(requests).toHaveLength(1)
    expect(requests[0]).toContain("/approve")
    expect(setup.captureCharFrame()).toContain("HTTP 503")
    expect(setup.captureCharFrame()).toContain("Workspace edit")
  } finally {
    release()
    server.stop(true)
  }
})

test("late completion cannot close a replacement dialog", async () => {
  let finish!: (result: ReviewDecisionResult) => void
  let host!: ReturnType<typeof useDialog>
  const result = new Promise<ReviewDecisionResult>((resolve) => { finish = resolve })
  const setup = await testRender(() => (
    <DialogProvider>
      <Harness onReady={(dialog) => { host = dialog }} onDecide={() => result} />
    </DialogProvider>
  ), size)
  setups.push(setup)
  await setup.renderOnce()
  setup.mockInput.pressKey("a")
  await setup.renderOnce()
  host.replace(() => <text>Replacement dialog</text>)
  await setup.renderOnce()
  finish({ settled: demoPendingReviews(), failed: [] })
  await setup.renderOnce()
  expect(setup.captureCharFrame()).toContain("Replacement dialog")
})

test("batch HTTP decisions report each confirmed item and retain failures", async () => {
  const targets = demoPendingReviews()
  const server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    fetch(request) {
      const path = new URL(request.url).pathname
      if (path.includes("/commands/")) return new Response("conflict", { status: 409 })
      return Response.json({ status: "rejected" })
    },
  })
  try {
    const result = await decideSolidReviews(new VeaselApiClient(server.url.origin), "session", "reject", targets)
    expect(result.settled.map((item) => item.kind)).toEqual(["patch", "mcp"])
    expect(result.failed).toHaveLength(1)
    expect(result.failed[0]).toContain("HTTP 409")
  } finally {
    server.stop(true)
  }
})

test("partial batch completion keeps failed reviews in the panel", async () => {
  const setup = await testRender(() => (
    <DialogProvider>
      <Harness onDecide={() => ({
        settled: demoPendingReviews().filter((item) => item.kind !== "command"),
        failed: ["Command approval unavailable"],
      })} />
    </DialogProvider>
  ), size)
  setups.push(setup)
  await setup.renderOnce()
  setup.mockInput.pressKey("a", { shift: true })
  await setup.renderOnce()
  expect(setup.captureCharFrame()).toContain("Shell command")
  expect(setup.captureCharFrame()).toContain("1/1 pending")
  expect(setup.captureCharFrame()).toContain("Command approval unavailable")
})

test("unexpected decision errors preserve the queue and allow an explicit retry", async () => {
  let attempts = 0
  const setup = await testRender(() => (
    <DialogProvider>
      <Harness onDecide={(_decision, targets) => {
        attempts++
        if (attempts === 1) throw new Error("Connection lost")
        return { settled: targets, failed: [] }
      }} />
    </DialogProvider>
  ), size)
  setups.push(setup)
  await setup.renderOnce()
  setup.mockInput.pressKey("a")
  await setup.renderOnce()
  expect(setup.captureCharFrame()).toContain("Connection lost")
  expect(setup.captureCharFrame()).toContain("Workspace edit")
  setup.mockInput.pressKey("a")
  await setup.renderOnce()
  expect(attempts).toBe(2)
  expect(setup.captureCharFrame()).toContain("Shell command")
})
