/** @jsxImportSource @opentui/solid */
import { afterEach, describe, expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { App } from "./app"
import { compactDirectory, HomeSplash } from "./component/home-splash"
import {
  VEASEL_PORTRAIT_ROWS,
  VEASEL_PORTRAIT_WIDTH,
  portraitRowCells,
} from "../veasel-portrait"
import { themes } from "../themes"

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

  test("portrait row pairs render square pixel art in half-block cells", () => {
    const cells = portraitRowCells(
      themes.mint,
      VEASEL_PORTRAIT_ROWS[5] ?? "",
      VEASEL_PORTRAIT_ROWS[6] ?? "",
    )
    expect(cells.some((cell) => cell.glyph !== " ")).toBe(true)
    expect(
      cells.some(
        (cell) => cell.color === themes.mint.portrait.R || cell.background === themes.mint.portrait.R,
      ),
    ).toBe(true)
    expect(VEASEL_PORTRAIT_ROWS.length).toBe(32)
    expect(VEASEL_PORTRAIT_ROWS.every((row) => row.length <= VEASEL_PORTRAIT_WIDTH)).toBe(true)
    expect(VEASEL_PORTRAIT_ROWS.join("")).toContain("C")
    expect(cells).toHaveLength(VEASEL_PORTRAIT_WIDTH)
    expect(cells.some((cell) => cell.glyph === "▀" && cell.background !== themes.mint.panelBg)).toBe(true)
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
    expect(frame).toContain("▀")
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
    expect(frame).toContain("▀")
    expect(frame).not.toContain("Start with a question or describe a coding task.")
  })
})
