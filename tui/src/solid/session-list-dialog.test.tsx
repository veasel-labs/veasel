/** @jsxImportSource @opentui/solid */
import { afterEach, describe, expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { App } from "./app"
import { demoSessions } from "./component/session-list-dialog"

const setups: Array<Awaited<ReturnType<typeof testRender>>> = []

afterEach(() => {
  for (const setup of setups.splice(0)) {
    setup.renderer.destroy()
  }
})

const demoSize = { width: 80, height: 30, kittyKeyboard: true } as const

describe("Solid session list + rename dialogs", () => {
  test("palette opens the session list with demo fixtures", async () => {
    const setup = await testRender(
      () => (
        <App
          initialMessages={[]}
          initialReviews={[]}
          initialSessions={demoSessions()}
        />
      ),
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()

    setup.mockInput.pressKey("p", { ctrl: true })
    await setup.renderOnce()
    await setup.mockInput.typeText("session list")
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Session list")

    setup.mockInput.pressEnter()
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Sessions")
    expect(frame).toContain("Solid transcript")
    expect(frame).toContain("Review queue polish")
    expect(frame).toContain("Filter sessions")
  })

  test("filter narrows sessions and Enter selects", async () => {
    const setup = await testRender(
      () => (
        <App
          initialMessages={[]}
          initialReviews={[]}
          initialSessions={demoSessions()}
        />
      ),
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()

    setup.mockInput.pressKey("p", { ctrl: true })
    await setup.renderOnce()
    await setup.mockInput.typeText("session list")
    await setup.renderOnce()
    setup.mockInput.pressEnter()
    await setup.renderOnce()

    await setup.mockInput.typeText("MCP")
    await setup.renderOnce()
    let frame = setup.captureCharFrame()
    expect(frame).toContain("MCP credentials")
    expect(frame).not.toContain("Review queue polish")

    setup.mockInput.pressEnter()
    await setup.renderOnce()
    frame = setup.captureCharFrame()
    expect(frame).not.toContain("Filter sessions")
    expect(frame).toContain("MCP credentials")
  })

  test("r opens rename and Enter saves the title", async () => {
    const setup = await testRender(
      () => (
        <App
          initialMessages={[]}
          initialReviews={[]}
          initialSessions={demoSessions()}
        />
      ),
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()

    setup.mockInput.pressKey("p", { ctrl: true })
    await setup.renderOnce()
    await setup.mockInput.typeText("session list")
    await setup.renderOnce()
    setup.mockInput.pressEnter()
    await setup.renderOnce()

    // Bare `r` (filter empty) — focused <input> can swallow Ctrl+E as readline.
    setup.mockInput.pressKey("r")
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Rename session")

    // Clear and type a new title via selecting all isn't available; append suffix.
    await setup.mockInput.typeText(" v2")
    await setup.renderOnce()
    setup.mockInput.pressEnter()
    await setup.renderOnce()

    const frame = setup.captureCharFrame()
    expect(frame).toContain("Sessions")
    expect(frame).toContain("Solid transcript v2")
  })

  test("Esc from rename returns to the session list", async () => {
    const setup = await testRender(
      () => (
        <App
          initialMessages={[]}
          initialReviews={[]}
          initialSessions={demoSessions()}
        />
      ),
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()

    setup.mockInput.pressKey("p", { ctrl: true })
    await setup.renderOnce()
    await setup.mockInput.typeText("session list")
    await setup.renderOnce()
    setup.mockInput.pressEnter()
    await setup.renderOnce()

    setup.mockInput.pressKey("r")
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Rename session")

    setup.mockInput.pressEscape()
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Sessions")
    expect(frame).toContain("Filter sessions")
    expect(frame).not.toContain("Rename session")
  })
})
