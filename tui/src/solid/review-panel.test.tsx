/** @jsxImportSource @opentui/solid */
import { afterEach, describe, expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { App } from "./app"
import { demoPendingReviews, reviewShortcut } from "./reviews"
import type { ActiveReview } from "../active-review"
import type { ReviewDecision } from "./reviews"

const setups: Array<Awaited<ReturnType<typeof testRender>>> = []

afterEach(() => {
  for (const setup of setups.splice(0)) {
    setup.renderer.destroy()
  }
})

const demoSize = { width: 80, height: 30, kittyKeyboard: true } as const

describe("Solid review panel", () => {
  test("Ctrl+R opens the pending review overlay with mint chrome", async () => {
    const setup = await testRender(
      () => <App initialMessages={[]} initialReviews={demoPendingReviews()} />,
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()

    expect(setup.captureCharFrame()).toContain(reviewShortcut.label)
    expect(setup.captureCharFrame()).toContain("attention")

    setup.mockInput.pressKey("r", { ctrl: true })
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Review")
    expect(frame).toContain("Workspace edit")
    expect(frame).toContain("reviews.ts")
    expect(frame).toContain("a approve")
    expect(frame).toContain("Ctrl+R")
  })

  test("review controls remain available in a narrow, short terminal", async () => {
    const setup = await testRender(
      () => <App initialMessages={[]} initialReviews={demoPendingReviews()} />,
      { width: 32, height: 12, kittyKeyboard: true },
    )
    setups.push(setup)
    await setup.renderOnce()
    setup.mockInput.pressKey("r", { ctrl: true })
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Review")
    expect(frame).toContain("a approve")
    expect(frame).toContain("pending")

    setup.mockInput.pressKey("v")
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Hunk 1/2")
    setup.mockInput.pressKey("}")
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Hunk 2/2")
  })

  test("a approves the current review and advances the queue", async () => {
    const decided: Array<{ decision: ReviewDecision; targets: ActiveReview[] }> = []
    const setup = await testRender(
      () => (
        <App
          initialMessages={[]}
          initialReviews={demoPendingReviews()}
          onReviewDecide={(decision, targets) => {
            decided.push({ decision, targets })
          }}
        />
      ),
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()

    setup.mockInput.pressKey("r", { ctrl: true })
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Workspace edit")

    setup.mockInput.pressKey("a")
    await setup.renderOnce()
    expect(decided).toHaveLength(1)
    expect(decided[0]!.decision).toBe("approve")
    expect(decided[0]!.targets[0]!.kind).toBe("patch")

    const frame = setup.captureCharFrame()
    // After the edit is settled, the shell command review should be active.
    expect(frame).toContain("Shell command")
    expect(frame).toContain("bun test")
  })

  test("] navigates to the next pending review", async () => {
    const setup = await testRender(
      () => <App initialMessages={[]} initialReviews={demoPendingReviews()} />,
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()

    setup.mockInput.pressKey("r", { ctrl: true })
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Workspace edit")

    setup.mockInput.pressKey("]")
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Shell command")
  })

  test("v toggles split DiffRenderable chrome for patch reviews", async () => {
    const setup = await testRender(
      () => <App initialMessages={[]} initialReviews={demoPendingReviews()} />,
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()

    setup.mockInput.pressKey("r", { ctrl: true })
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("v split")

    setup.mockInput.pressKey("v")
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("EDIT / pending")
    expect(frame).toContain("v word")
  })

  test("} scrolls the split diff to the selected hunk", async () => {
    const setup = await testRender(
      () => <App initialMessages={[]} initialReviews={demoPendingReviews()} />,
      { width: 80, height: 20, kittyKeyboard: true },
    )
    setups.push(setup)
    await setup.renderOnce()

    setup.mockInput.pressKey("r", { ctrl: true })
    await setup.renderOnce()
    setup.mockInput.pressKey("v")
    await setup.renderOnce()
    await Promise.resolve()
    const firstHunkFrame = setup.captureCharFrame()

    setup.mockInput.pressKey("}")
    await setup.renderOnce()
    await Promise.resolve()
    const secondHunkFrame = setup.captureCharFrame()
    expect(firstHunkFrame).not.toContain("+   // pending")
    expect(secondHunkFrame).toContain("+   // pending")
    expect(secondHunkFrame).toContain("Hunk 2/2")
  })

  test("Esc dismisses the review panel", async () => {
    const setup = await testRender(
      () => <App initialMessages={[]} initialReviews={demoPendingReviews()} />,
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()

    setup.mockInput.pressKey("r", { ctrl: true })
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("a approve")

    setup.mockInput.pressEscape()
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).not.toContain("a approve")
    expect(frame).toContain("VEASEL")
  })

  test("palette open-reviews command opens the panel", async () => {
    const setup = await testRender(
      () => <App initialMessages={[]} initialReviews={demoPendingReviews()} />,
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()

    setup.mockInput.pressKey("p", { ctrl: true })
    await setup.renderOnce()
    await setup.mockInput.typeText("pending reviews")
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Open pending reviews")

    setup.mockInput.pressEnter()
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Workspace edit")
  })
})
