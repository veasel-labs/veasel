/** @jsxImportSource @opentui/solid */
import { afterEach, describe, expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { App } from "./app"
import { buildOpenRootOptions, demoOpenProjects } from "./component/open-dialog"
import { demoSessions } from "./component/session-list-dialog"

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

describe("Solid parity wave dialogs", () => {
  test("buildOpenRootOptions lists sessions before projects", () => {
    const options = buildOpenRootOptions({
      recentSessions: demoSessions(),
      projects: demoOpenProjects(),
    })
    expect(options[0]?.category).toBe("Recent sessions")
    expect(options.some((item) => item.category === "Projects")).toBe(true)
  })

  test("Ctrl+O opens Open dialog", async () => {
    const setup = await testRender(() => <App initialMessages={[]} initialReviews={[]} />, demoSize)
    setups.push(setup)
    await setup.renderOnce()
    setup.mockInput.pressKey("o", { ctrl: true })
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Open")
    expect(frame).toContain("Recent sessions")
  })

  test("palette opens status dialog with MCP lines", async () => {
    const setup = await testRender(() => <App initialMessages={[]} initialReviews={[]} />, demoSize)
    setups.push(setup)
    await setup.renderOnce()
    await openPaletteCommand(setup, "usage summary")
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Status")
    expect(frame).toContain("filesystem")
  })

  test("palette opens agent picker", async () => {
    const setup = await testRender(() => <App initialMessages={[]} initialReviews={[]} />, demoSize)
    setups.push(setup)
    await setup.renderOnce()
    await openPaletteCommand(setup, "select agent")
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Select agent")
    expect(frame).toContain("build")
  })

  test("palette opens update dialog with changelog stub", async () => {
    const setup = await testRender(() => <App initialMessages={[]} initialReviews={[]} />, demoSize)
    setups.push(setup)
    await setup.renderOnce()
    await openPaletteCommand(setup, "check for updates")
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Update available")
    expect(frame).toContain("Solid dialog parity")
  })

  test("palette opens device pairing N/A alert", async () => {
    const setup = await testRender(() => <App initialMessages={[]} initialReviews={[]} />, demoSize)
    setups.push(setup)
    await setup.renderOnce()
    await openPaletteCommand(setup, "device pairing")
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Device pairing")
    expect(frame).toContain("Not available")
  })

  test("palette opens workspaces with worktree action", async () => {
    const setup = await testRender(() => <App initialMessages={[]} initialReviews={[]} />, demoSize)
    setups.push(setup)
    await setup.renderOnce()
    await openPaletteCommand(setup, "workspaces")
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Workspaces")
    expect(frame).toContain("New worktree")
  })

  test("palette opens image preview stub", async () => {
    const setup = await testRender(() => <App initialMessages={[]} initialReviews={[]} />, demoSize)
    setups.push(setup)
    await setup.renderOnce()
    await openPaletteCommand(setup, "image preview")
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Image preview")
    expect(frame).toContain("VEASEL code")
  })
})
