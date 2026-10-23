/** @jsxImportSource @opentui/solid */
import { afterEach, describe, expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { App } from "./app"
import { compactDirectory, HomeSplash } from "./component/home-splash"
import {
  VEASEL_PORTRAIT_ROWS,
  VEASEL_PORTRAIT_WIDTH,
  portraitRowPlain,
} from "../veasel-portrait"

const setups: Array<Awaited<ReturnType<typeof testRender>>> = []

afterEach(() => {
  for (const setup of setups.splice(0)) {
    setup.renderer.destroy()
  }
})

const demoSize = { width: 80, height: 30, kittyKeyboard: true } as const

describe("Veasel home splash + pixel portrait", () => {
  test("long project paths keep a readable suffix within the pane width", () => {
    expect(compactDirectory("/home/user/worktrees/project", 12)).toBe("…/project")
    expect(compactDirectory("C:\\Users\\name\\project", 12)).toBe("…\\project")
    expect(compactDirectory("~/short", 12)).toBe("~/short")
    expect(compactDirectory("/tmp/long-project-name", 6)).toBe("…-name")
  })

  test("portrait rows render as double-width blocks", () => {
    const plain = portraitRowPlain(VEASEL_PORTRAIT_ROWS[0])
    expect(plain.includes("██")).toBe(true)
    expect(VEASEL_PORTRAIT_ROWS.length).toBe(17)
    expect(VEASEL_PORTRAIT_ROWS.every((row) => row.length <= VEASEL_PORTRAIT_WIDTH)).toBe(true)
    expect(portraitRowPlain(VEASEL_PORTRAIT_ROWS[0]).length).toBe(VEASEL_PORTRAIT_WIDTH * 2)
  })

  test("HomeSplash shows brand and mascot chrome at 80×30", async () => {
    const setup = await testRender(() => <HomeSplash directory="~/veasel" />, demoSize)
    setups.push(setup)
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("VEASEL CODE")
    expect(frame).toContain("~/veasel")
    expect(frame).toContain("/connect")
    expect(frame).toContain("Ctrl+P")
    expect(frame).toContain("Ctrl+R reviews")
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
