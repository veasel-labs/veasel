/** @jsxImportSource @opentui/solid */
import { afterEach, describe, expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { onMount } from "solid-js"
import { App } from "./app"
import { buildPaletteCommands, paletteShortcut } from "./commands"
import { CommandPalette } from "./component/command-palette"
import { DialogProvider, useDialog } from "./ui/dialog"

const setups: Array<Awaited<ReturnType<typeof testRender>>> = []

afterEach(() => {
  for (const setup of setups.splice(0)) {
    setup.renderer.destroy()
  }
})

// kittyKeyboard so Esc is unambiguous (bare ESC waits on a timeout otherwise).
const demoSize = { width: 80, height: 30, kittyKeyboard: true } as const

describe("Solid dialog host + command palette", () => {
  test("Ctrl+P opens the palette and Esc dismisses it", async () => {
    const setup = await testRender(() => <App initialMessages={[]} />, demoSize)
    setups.push(setup)
    await setup.renderOnce()

    expect(setup.captureCharFrame()).toContain(paletteShortcut.label)
    expect(setup.captureCharFrame()).not.toContain("Filter commands")

    setup.mockInput.pressKey("p", { ctrl: true })
    await setup.renderOnce()
    let frame = setup.captureCharFrame()
    expect(frame).toContain("Commands")
    expect(frame).toContain("Filter commands")
    expect(frame).toContain("Show quick help")

    setup.mockInput.pressEscape()
    await setup.renderOnce()
    frame = setup.captureCharFrame()
    expect(frame).not.toContain("Filter commands")
    expect(frame).toContain("VEASEL")
  })

  test("filter narrows the command list", async () => {
    const setup = await testRender(() => <App initialMessages={[]} />, demoSize)
    setups.push(setup)
    await setup.renderOnce()

    setup.mockInput.pressKey("p", { ctrl: true })
    await setup.renderOnce()
    // Chrome actions stay on the first screen; slash commands are filter-reachable.
    expect(setup.captureCharFrame()).toContain("Open pending reviews")

    await setup.mockInput.typeText("theme")
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("/theme")
    expect(frame).toContain("Cycle theme")
    expect(frame).not.toContain("Open pending reviews")
    expect(frame).not.toContain("/connect")
  })

  test("keyboard select runs the highlighted action", async () => {
    const ran: string[] = []
    function Fixture() {
      const dialog = useDialog()
      const commands = buildPaletteCommands({
        showHelp: () => ran.push("help"),
        runSlash: (name) => ran.push(name),
        cycleTheme: () => {
          ran.push("theme")
          return "ember"
        },
        showSessions: () => ran.push("sessions"),
        toggleActivity: () => ran.push("activity"),
        openReviews: () => ran.push("reviews"),
        showToast: () => ran.push("toast"),
        showConfirm: () => ran.push("confirm"),
        showThemeList: () => ran.push("themes"),
        showModelPicker: () => ran.push("model"),
        showStash: () => ran.push("stash"),
        showErrorDetails: () => ran.push("error"),
        showShellOutput: () => ran.push("shell"),
        showMcp: () => ran.push("mcp"),
        showSkills: () => ran.push("skills"),
        showExport: () => ran.push("export"),
        showAgent: () => ran.push("agent"),
        showVariant: () => ran.push("variant"),
        showWorkspaces: () => ran.push("workspaces"),
      })
      onMount(() => {
        dialog.replace(() => <CommandPalette commands={commands} />)
      })
      return (
        <box width="100%" height="100%">
          <text>fixture</text>
        </box>
      )
    }

    const setup = await testRender(
      () => (
        <DialogProvider>
          <Fixture />
        </DialogProvider>
      ),
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()
    await setup.renderOnce()

    expect(setup.captureCharFrame()).toContain("Show quick help")
    setup.mockInput.pressEnter()
    await setup.renderOnce()
    expect(ran).toEqual(["help"])
    expect(setup.captureCharFrame()).not.toContain("Filter commands")
  })

  test("arrow down then Enter runs the next command", async () => {
    const ran: string[] = []
    function Fixture() {
      const dialog = useDialog()
      const commands = buildPaletteCommands({
        showHelp: (compact) => ran.push(compact ? "compact" : "full"),
        runSlash: () => {},
        cycleTheme: () => "mint",
        showSessions: () => {},
        toggleActivity: () => {},
        openReviews: () => {},
        showToast: () => {},
        showConfirm: () => {},
        showThemeList: () => {},
        showModelPicker: () => {},
        showStash: () => {},
        showErrorDetails: () => {},
        showShellOutput: () => {},
        showMcp: () => {},
        showSkills: () => {},
        showExport: () => {},
        showAgent: () => {},
        showVariant: () => {},
        showWorkspaces: () => {},
      })
      onMount(() => {
        dialog.replace(() => <CommandPalette commands={commands} maxVisible={10} />)
      })
      return <box width="100%" height="100%" />
    }

    const setup = await testRender(
      () => (
        <DialogProvider>
          <Fixture />
        </DialogProvider>
      ),
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()
    await setup.renderOnce()

    setup.mockInput.pressArrow("down")
    await setup.renderOnce()
    setup.mockInput.pressEnter()
    await setup.renderOnce()
    expect(ran).toEqual(["full"])
  })

  test("Ctrl+P toggles the palette closed from App", async () => {
    const setup = await testRender(() => <App initialMessages={[]} />, demoSize)
    setups.push(setup)
    await setup.renderOnce()

    setup.mockInput.pressKey("p", { ctrl: true })
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Commands")

    setup.mockInput.pressKey("p", { ctrl: true })
    await setup.renderOnce()
    expect(setup.captureCharFrame()).not.toContain("Filter commands")
  })
})

describe("Solid palette dialog stubs", () => {
  test("selecting help from App opens the Help dialog", async () => {
    const setup = await testRender(() => <App initialMessages={[]} />, demoSize)
    setups.push(setup)
    await setup.renderOnce()

    setup.mockInput.pressKey("p", { ctrl: true })
    await setup.renderOnce()
    setup.mockInput.pressEnter()
    await setup.renderOnce()

    const frame = setup.captureCharFrame()
    expect(frame).toContain("Help")
    expect(frame).toContain("VEASEL CODE / QUICK HELP")
    expect(frame).toContain(paletteShortcut.label)
    expect(frame).not.toContain("Filter commands")
  })
})
