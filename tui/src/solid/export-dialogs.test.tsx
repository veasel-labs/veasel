/** @jsxImportSource @opentui/solid */
import { afterEach, describe, expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { App } from "./app"

const setups: Array<Awaited<ReturnType<typeof testRender>>> = []

afterEach(() => {
  for (const setup of setups.splice(0)) {
    setup.renderer.destroy()
  }
})

const demoSize = { width: 80, height: 30, kittyKeyboard: true } as const

async function openPaletteCommand(setup: Awaited<ReturnType<typeof testRender>>, query: string) {
  setup.mockInput.pressKey("p", { ctrl: true })
  await setup.renderOnce()
  await setup.mockInput.typeText(query)
  await setup.renderOnce()
  setup.mockInput.pressEnter()
  await setup.renderOnce()
}

describe("Solid export dialogs", () => {
  test("palette opens export options with markdown defaults", async () => {
    const setup = await testRender(() => <App initialMessages={[]} initialReviews={[]} />, demoSize)
    setups.push(setup)
    await setup.renderOnce()
    await openPaletteCommand(setup, "export session")
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Export session")
    expect(frame).toContain("Markdown")
    expect(frame).toContain("Include thinking")
    expect(frame).toContain("Include tools")
  })

  test("export action shows result path dialog", async () => {
    const setup = await testRender(() => <App initialMessages={[]} initialReviews={[]} />, demoSize)
    setups.push(setup)
    await setup.renderOnce()
    await openPaletteCommand(setup, "export session")
    setup.mockInput.pressKey("x")
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Session exported")
    expect(frame).toContain("veasel-session")
    expect(frame).toMatch(/\.md|\.json/)
  })
})
