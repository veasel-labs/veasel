import { describe, expect, test } from "bun:test"
import {
  buildPaletteCommands,
  filterPaletteCommands,
  nextBuiltinThemeId,
  paletteHelpText,
  paletteShortcut,
  type PaletteCommand,
} from "./commands"
import { slashCommands } from "../slash-commands"

describe("Solid palette commands", () => {
  test("documents Ctrl+P (not Ctrl+K) as the palette shortcut", () => {
    expect(paletteShortcut.label).toBe("Ctrl+P")
    expect(paletteShortcut.name).toBe("p")
    expect(paletteShortcut.ctrl).toBe(true)
  })

  test("builds actions from slash helpers plus guide/theme/session stubs", () => {
    const ran: string[] = []
    const commands = buildPaletteCommands({
      showHelp: () => ran.push("help"),
      runSlash: (name) => ran.push(name),
      cycleTheme: () => {
        ran.push("theme")
        return "ember"
      },
      showSessions: () => ran.push("sessions"),
    })

    expect(commands.some((command) => command.id === "veasel.help")).toBe(true)
    expect(commands.some((command) => command.id === "veasel.theme.cycle")).toBe(true)
    expect(commands.some((command) => command.id === "veasel.session.list")).toBe(true)
    expect(commands.filter((command) => command.id.startsWith("veasel.slash.")).length).toBe(
      slashCommands.length,
    )

    commands.find((command) => command.id === "veasel.help")!.run()
    commands.find((command) => command.title === "/map")!.run()
    expect(ran).toEqual(["help", "/map"])
  })

  test("filters by title, group, and keywords", () => {
    const sample: PaletteCommand[] = [
      {
        id: "a",
        title: "Show quick help",
        description: "guide",
        group: "guide",
        keywords: ["?"],
        run: () => {},
      },
      {
        id: "b",
        title: "/theme",
        description: "colors",
        group: "setup",
        run: () => {},
      },
    ]
    expect(filterPaletteCommands(sample, "help").map((item) => item.id)).toEqual(["a"])
    expect(filterPaletteCommands(sample, "setup theme").map((item) => item.id)).toEqual(["b"])
    expect(filterPaletteCommands(sample, "zzz")).toEqual([])
  })

  test("cycles builtin theme ids", () => {
    expect(nextBuiltinThemeId("mint")).toBe("ember")
    expect(nextBuiltinThemeId("contrast")).toBe("mint")
  })

  test("palette help text comes from renderHelp", () => {
    expect(paletteHelpText(true)).toContain("VEASEL CODE / QUICK HELP")
    expect(paletteHelpText(false)).toContain("/connect")
  })
})
