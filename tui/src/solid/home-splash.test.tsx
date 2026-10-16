/** @jsxImportSource @opentui/solid */
import { afterEach, describe, expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { App } from "./app"
import { HomeSplash } from "./component/home-splash"
import { VEASEL_PORTRAIT_ROWS, portraitRowPlain } from "../veasel-portrait"

const setups: Array<Awaited<ReturnType<typeof testRender>>> = []

afterEach(() => {
  for (const setup of setups.splice(0)) {
    setup.renderer.destroy()
  }
})

const demoSize = { width: 80, height: 30, kittyKeyboard: true } as const

describe("Veasel home splash + pixel portrait", () => {
  test("portrait rows render as double-width blocks", () => {
    const plain = portraitRowPlain(VEASEL_PORTRAIT_ROWS[0])
    expect(plain.includes("██")).toBe(true)
    expect(VEASEL_PORTRAIT_ROWS.length).toBe(16)
  })

  test("HomeSplash shows brand and mascot chrome at 80×30", async () => {
    const setup = await testRender(() => <HomeSplash directory="~/veasel" />, demoSize)
    setups.push(setup)
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("VEASEL CODE")
    expect(frame).toContain("your local V-powered workspace")
    expect(frame).toContain("~/veasel")
    expect(frame).toContain("/connect")
    expect(frame).toContain("Ctrl+P")
    expect(frame).toContain("PIXEL VEASEL")
    // Block pixels from the portrait should appear.
    expect(frame).toContain("██")
  })

  test("empty App session shows the splash instead of transcript hint", async () => {
    const setup = await testRender(
      () => <App initialMessages={[]} initialReviews={[]} />,
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("VEASEL CODE")
    expect(frame).toContain("Ctrl+P")
    expect(frame).toContain("██")
    expect(frame).not.toContain("Start with a question or describe a coding task.")
  })
})
