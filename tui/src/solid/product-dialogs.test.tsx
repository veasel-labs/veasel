/** @jsxImportSource @opentui/solid */
import { afterEach, describe, expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { App } from "./app"
import { buildModelSelectOptions, catalogEntryToSolidModel, demoFavoriteModels, demoModels, demoRecentModels } from "./component/model-dialog"
import { demoStashEntries } from "./component/stash-dialog"

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

describe("Solid product dialogs", () => {
  test("buildModelSelectOptions puts favorites and recents first", () => {
    const options = buildModelSelectOptions({
      models: demoModels(),
      favorites: demoFavoriteModels(),
      recents: demoRecentModels(),
    })
    expect(options[0]?.category).toBe("Favorites")
    expect(options[0]?.title).toBe("Claude Sonnet 4")
    expect(options.some((item) => item.category === "Recent")).toBe(true)
    expect(demoStashEntries().length).toBeGreaterThan(0)
  })

  test("model catalog privacy disclosures are visible in picker options", () => {
    const model = catalogEntryToSolidModel("opencode-go", "OpenCode Go", {
      id: "iceman-contributor-free",
      name: "Iceman Contributor Free",
      data_use_notice: "Prompts may be used to improve this model.",
    })
    const [option] = buildModelSelectOptions({ models: [model] })
    expect(option?.footer).toContain("⚠ Prompts may be used to improve this model.")
  })

  test("palette opens model picker with favorites section", async () => {
    const setup = await testRender(() => <App initialMessages={[]} initialReviews={[]} />, demoSize)
    setups.push(setup)
    await setup.renderOnce()
    await openPaletteCommand(setup, "select model")
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Select model")
    expect(frame).toContain("Favorites")
    expect(frame).toContain("Claude Sonnet 4")
  })

  test("palette opens stash dialog", async () => {
    const setup = await testRender(() => <App initialMessages={[]} initialReviews={[]} />, demoSize)
    setups.push(setup)
    await setup.renderOnce()
    await openPaletteCommand(setup, "prompt stash")
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Stash")
    expect(frame).toContain("Explain the Solid dialog host")
  })

  test("palette opens error details dialog", async () => {
    const setup = await testRender(() => <App initialMessages={[]} initialReviews={[]} />, demoSize)
    setups.push(setup)
    await setup.renderOnce()
    await openPaletteCommand(setup, "error details")
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Provider error")
    expect(frame).toContain("rate_limit_error")
  })

  test("palette opens shell output dialog", async () => {
    const setup = await testRender(() => <App initialMessages={[]} initialReviews={[]} />, demoSize)
    setups.push(setup)
    await setup.renderOnce()
    await openPaletteCommand(setup, "shell output")
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Shell output")
    expect(frame).toContain("bun test")
  })

  test("palette opens theme list", async () => {
    const setup = await testRender(() => <App initialMessages={[]} initialReviews={[]} />, demoSize)
    setups.push(setup)
    await setup.renderOnce()
    await openPaletteCommand(setup, "theme list")
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Themes")
    expect(frame).toContain("mint")
  })

  test("palette opens MCP servers dialog", async () => {
    const setup = await testRender(() => <App initialMessages={[]} initialReviews={[]} />, demoSize)
    setups.push(setup)
    await setup.renderOnce()
    await openPaletteCommand(setup, "mcp servers")
    const frame = setup.captureCharFrame()
    expect(frame).toContain("MCP servers")
    expect(frame).toContain("filesystem")
    expect(frame).toContain("Connected")
  })

  test("MCP failed server opens error details", async () => {
    const setup = await testRender(() => <App initialMessages={[]} initialReviews={[]} />, demoSize)
    setups.push(setup)
    await setup.renderOnce()
    await openPaletteCommand(setup, "mcp servers")
    await setup.mockInput.typeText("echo")
    await setup.renderOnce()
    setup.mockInput.pressEnter()
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("MCP · echo-tools")
    expect(frame).toContain("spawn ENOENT")
  })

  test("palette opens skills dialog", async () => {
    const setup = await testRender(() => <App initialMessages={[]} initialReviews={[]} />, demoSize)
    setups.push(setup)
    await setup.renderOnce()
    await openPaletteCommand(setup, "skills")
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Skills")
    expect(frame).toContain("code-review")
  })

  test("palette opens agent picker", async () => {
    const setup = await testRender(() => <App initialMessages={[]} initialReviews={[]} />, demoSize)
    setups.push(setup)
    await setup.renderOnce()
    await openPaletteCommand(setup, "select agent")
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Select agent")
    expect(frame).toContain("build")
    expect(frame).toContain("plan")
  })

  test("palette opens variant picker", async () => {
    const setup = await testRender(() => <App initialMessages={[]} initialReviews={[]} />, demoSize)
    setups.push(setup)
    await setup.renderOnce()
    await openPaletteCommand(setup, "select variant")
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Select variant")
    expect(frame).toContain("Default")
    expect(frame).toContain("fast")
  })

  test("palette opens workspaces dialog", async () => {
    const setup = await testRender(() => <App initialMessages={[]} initialReviews={[]} />, demoSize)
    setups.push(setup)
    await setup.renderOnce()
    await openPaletteCommand(setup, "workspaces")
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Workspaces")
    expect(frame).toContain("Worktrees")
    expect(frame).toContain("tui-solid")
  })
})
