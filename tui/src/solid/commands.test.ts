import { describe, expect, test } from "bun:test"
import {
  buildLivePaletteCommands,
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
      showOpen: () => ran.push("open"),
      showStatus: () => ran.push("status"),
      showAgent: () => ran.push("agent"),
      showVariant: () => ran.push("variant"),
      showWorkspaces: () => ran.push("workspaces"),
      showUpdate: () => ran.push("update"),
      showPair: () => ran.push("pair"),
      showHighlights: () => ran.push("highlights"),
      showImagePreview: () => ran.push("image"),
    })

    expect(commands.some((command) => command.id === "veasel.help")).toBe(true)
    expect(commands.some((command) => command.id === "veasel.theme.cycle")).toBe(true)
    expect(commands.some((command) => command.id === "veasel.theme.list")).toBe(true)
    expect(commands.some((command) => command.id === "veasel.session.list")).toBe(true)
    expect(commands.some((command) => command.id === "veasel.activity.toggle")).toBe(true)
    expect(commands.some((command) => command.id === "veasel.reviews.open")).toBe(true)
    expect(commands.some((command) => command.id === "veasel.toast.demo")).toBe(true)
    expect(commands.some((command) => command.id === "veasel.confirm.demo")).toBe(true)
    expect(commands.some((command) => command.id === "veasel.model.picker")).toBe(true)
    expect(commands.some((command) => command.id === "veasel.stash.list")).toBe(true)
    expect(commands.some((command) => command.id === "veasel.error.details")).toBe(true)
    expect(commands.some((command) => command.id === "veasel.shell.output")).toBe(true)
    expect(commands.some((command) => command.id === "veasel.mcp.list")).toBe(true)
    expect(commands.some((command) => command.id === "veasel.skills.list")).toBe(true)
    expect(commands.some((command) => command.id === "veasel.session.export")).toBe(true)
    expect(commands.some((command) => command.id === "veasel.open.dialog")).toBe(true)
    expect(commands.some((command) => command.id === "veasel.status.dialog")).toBe(true)
    expect(commands.some((command) => command.id === "veasel.agent.picker")).toBe(true)
    expect(commands.some((command) => command.id === "veasel.workspaces.list")).toBe(true)
    expect(commands.filter((command) => command.id.startsWith("veasel.slash.")).length).toBe(
      slashCommands.length,
    )

    commands.find((command) => command.id === "veasel.help")!.run()
    commands.find((command) => command.title === "/map")!.run()
    commands.find((command) => command.id === "veasel.activity.toggle")!.run()
    commands.find((command) => command.id === "veasel.reviews.open")!.run()
    commands.find((command) => command.id === "veasel.toast.demo")!.run()
    commands.find((command) => command.id === "veasel.confirm.demo")!.run()
    commands.find((command) => command.id === "veasel.model.picker")!.run()
    expect(ran).toEqual(["help", "/map", "activity", "reviews", "toast", "confirm", "model"])
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

  test("live palette exposes settings, theme, stash, open, workspaces, quit", () => {
    const ran: string[] = []
    const commands = buildLivePaletteCommands({
      showHelp: () => ran.push("help"),
      openSettings: () => ran.push("settings"),
      createSession: () => ran.push("new"),
      openRecent: () => ran.push("open"),
      openWorkspaces: () => ran.push("workspaces"),
      stashDraft: () => ran.push("stash"),
      showStash: () => ran.push("stash-list"),
      cycleTheme: () => ran.push("theme"),
      attachFile: () => ran.push("attach"),
      showSessionDiffs: () => ran.push("diff"),
      nextSessionTab: () => ran.push("tab-next"),
      prevSessionTab: () => ran.push("tab-prev"),
      quit: () => ran.push("quit"),
    })
    expect(commands.map((command) => command.id)).toEqual([
      "veasel.help",
      "veasel.settings",
      "veasel.theme.cycle",
      "veasel.session.new",
      "veasel.open",
      "veasel.workspaces",
      "veasel.stash.push",
      "veasel.stash.list",
      "veasel.attach.file",
      "veasel.session.diff",
      "veasel.session.tab.next",
      "veasel.session.tab.prev",
      "veasel.quit",
    ])
    expect(filterPaletteCommands(commands, "provider").map((c) => c.id)).toEqual(["veasel.settings"])
    expect(filterPaletteCommands(commands, "stash").map((c) => c.id)).toEqual([
      "veasel.stash.push",
      "veasel.stash.list",
    ])
    commands.find((command) => command.id === "veasel.settings")!.run()
    commands.find((command) => command.id === "veasel.open")!.run()
    commands.find((command) => command.id === "veasel.theme.cycle")!.run()
    expect(ran).toEqual(["settings", "open", "theme"])
  })
})
