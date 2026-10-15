import { describe, expect, test } from "bun:test"
import { helpItems } from "./help"
import {
  completeSlashCommand,
  jumpSuggestion,
  moveSuggestion,
  runsOnAccept,
  slashCategoryLabel,
  slashCommands,
  slashContextApplies,
  slashSuggestions,
  suggestionWindow,
} from "./slash-commands"

const names = (input: string) => slashSuggestions(input).map((command) => command.name)

describe("slashSuggestions", () => {
  test("lists every command for a bare slash and nothing for plain prompts", () => {
    expect(names("/")).toHaveLength(slashCommands.length)
    expect(names("")).toEqual([])
    expect(names("explain /mcp")).toEqual([])
    expect(slashCommands.every((command) => Boolean(command.category))).toBe(true)
    expect(slashCategoryLabel(slashCommands.find((command) => command.name === "/connect")!)).toBe("setup")
    expect(slashCategoryLabel(slashCommands.find((command) => command.name === "/patches")!)).toBe("review")
    expect(slashCategoryLabel(slashCommands.find((command) => command.name === "/mcp")!)).toBe("mcp")
    expect(slashCategoryLabel(slashCommands.find((command) => command.name === "/skills")!)).toBe("skills")
  })

  test("filters by prefix and ranks an exact match first", () => {
    expect(names("/pa")).toEqual(["/patches", "/patch"])
    expect(names("/patch")[0]).toBe("/patch")
    expect(names("/mcp")[0]).toBe("/mcp")
    expect(names("/mcp c")).toEqual(["/mcp credentials", "/mcp credential", "/mcp calls", "/mcp call"])
    expect(names("/mcp a")).toEqual(["/mcp add"])
    expect(names("/mcp add ")).toEqual(["/mcp add stdio", "/mcp add http", "/mcp add project", "/mcp add user"])
    expect(slashSuggestions("/mcp remove ", slashCommands, {
      configuredMcpServers: [{ value: "echo-tools", description: "enabled · stdio" }],
    }).map((item) => item.insert)).toEqual(["/mcp remove user ", "/mcp remove project "])
    expect(slashSuggestions("/mcp remove user ", slashCommands, {
      configuredMcpServers: [{ value: "echo-tools", description: "user · enabled · stdio" }],
    }).map((item) => item.insert)).toEqual(["/mcp remove user echo-tools"])
    expect(names("/con")[0]).toBe("/connect")
    expect(names("/connect")[0]).toBe("/connect")
  })

  test("is case-insensitive and tolerates repeated spaces", () => {
    expect(names("/HIST")).toEqual(["/history older"])
    expect(names("/mcp   tr")).toEqual(["/mcp trust"])
  })

  test("falls back to substring matches after prefix matches", () => {
    expect(names("/older")).toEqual(["/history older"])
    expect(names("/trust")).toEqual(["/mcp trust", "/mcp untrust"])
  })

  test("finds commands by description keywords after name matches", () => {
    expect(names("/key")[0]).toBe("/connect")
    expect(names("/auth")[0]).toBe("/connect")
    expect(names("/color")[0]).toBe("/theme")
    expect(names("/repo")[0]).toBe("/map")
    expect(names("/approval")).toEqual(["/patches", "/commands"])
  })

  test("finds pending values by description path fragments", () => {
    expect(slashSuggestions("/patch show main", slashCommands, {
      patches: [
        { value: "11111111-1111-1111-1111-111111111111", description: "pending · src/main.v" },
        { value: "22222222-2222-2222-2222-222222222222", description: "pending · README.md" },
      ],
    }).map((item) => item.insert)).toEqual(["/patch show 11111111-1111-1111-1111-111111111111"])
    expect(names("/theme warm")).toEqual(["/theme ember"])
  })

  test("suggests theme ids for /theme", () => {
    expect(names("/theme")[0]).toBe("/theme")
    expect(names("/theme ")).toEqual(["/theme mint", "/theme ember", "/theme slate", "/theme mono", "/theme aurora"])
    expect(names("/theme au")).toEqual(["/theme aurora"])
  })

  test("suggests subcommands and filters contextual values", () => {
    expect(names("/patch ")).toEqual(["/patch show", "/patch approve", "/patch reject"])
    expect(names("/patch sh")).toEqual(["/patch show"])
    expect(names("/skill ")).toEqual(["/skill on", "/skill off"])
    expect(names("/mcp call ")).toEqual(["/mcp call show", "/mcp call approve", "/mcp call reject"])
    const patches = slashSuggestions("/patch show ", slashCommands, {
      patches: [
        { value: "11111111-1111-1111-1111-111111111111", description: "pending · src/main.v" },
        { value: "22222222-2222-2222-2222-222222222222", description: "pending · README.md" },
      ],
    })
    expect(patches.map((item) => item.description)).toEqual(["pending · src/main.v", "pending · README.md"])
    expect(patches[0]?.insert).toBe("/patch show 11111111-1111-1111-1111-111111111111")
    expect(patches[0]?.run).toBe(true)
    expect(names("/patch show 2222")).toEqual([])
    expect(slashSuggestions("/patch show 2222", slashCommands, {
      patches: [{ value: "22222222-2222-2222-2222-222222222222", description: "pending · README.md" }],
    }).map((item) => item.insert)).toEqual(["/patch show 22222222-2222-2222-2222-222222222222"])
    expect(slashSuggestions("/skill on ", slashCommands, {
      skills: [{ value: "review-tools/review", description: "Review changes" }],
    }).map((item) => item.insert)).toEqual(["/skill on review-tools/review"])
    expect(names("/plugin")).toEqual(["/plugins", "/plugin add", "/plugin remove"])
    expect(slashSuggestions("/plugin remove ", slashCommands, {
      pluginLinks: [{ value: "review-tools", description: "/tmp/review-tools" }],
    }).map((item) => item.insert)).toEqual(["/plugin remove review-tools"])
    expect(names("/mcp add")).toEqual(["/mcp add"])
    expect(names("/mcp add ")).toEqual(["/mcp add stdio", "/mcp add http", "/mcp add project", "/mcp add user"])
    expect(slashSuggestions("/mcp remove project ", slashCommands, {
      configuredMcpServers: [{ value: "local-echo", description: "project · enabled · stdio" }],
    }).map((item) => item.insert)).toEqual(["/mcp remove project local-echo"])
  })

  test("returns nothing for an unknown command", () => {
    expect(names("/deploy")).toEqual([])
  })
})

describe("accepting a suggestion", () => {
  test("completes argument commands with a trailing space and does not run them", () => {
    const patch = slashCommands.find((command) => command.name === "/patch")!
    expect(completeSlashCommand(patch)).toBe("/patch ")
    expect(runsOnAccept(patch)).toBe(false)
  })

  test("runs commands that need no arguments", () => {
    const patches = slashCommands.find((command) => command.name === "/patches")!
    expect(completeSlashCommand(patches)).toBe("/patches")
    expect(runsOnAccept(patches)).toBe(true)
  })
})

describe("suggestion navigation", () => {
  test("wraps in both directions", () => {
    expect(moveSuggestion(0, -1, 3)).toBe(2)
    expect(moveSuggestion(2, 1, 3)).toBe(0)
    expect(moveSuggestion(0, 1, 0)).toBe(0)
  })

  test("keeps the selected row inside the visible window", () => {
    expect(suggestionWindow(0, 15)).toEqual({ start: 0, end: 6 })
    expect(suggestionWindow(8, 15)).toEqual({ start: 3, end: 9 })
    expect(suggestionWindow(14, 15)).toEqual({ start: 9, end: 15 })
    expect(suggestionWindow(2, 4)).toEqual({ start: 0, end: 4 })
  })

  test("jumps to edges and pages without wrapping", () => {
    expect(jumpSuggestion(4, 20, "home")).toBe(0)
    expect(jumpSuggestion(4, 20, "end")).toBe(19)
    expect(jumpSuggestion(8, 20, "pageup")).toBe(2)
    expect(jumpSuggestion(8, 20, "pagedown")).toBe(14)
    expect(jumpSuggestion(0, 20, "pageup")).toBe(0)
    expect(jumpSuggestion(18, 20, "pagedown")).toBe(19)
    expect(jumpSuggestion(0, 0, "end")).toBe(0)
  })
})

test("stale slash context from another session is discarded", () => {
  expect(slashContextApplies("session-a", "session-a")).toBe(true)
  expect(slashContextApplies("session-a", "session-b")).toBe(false)
  expect(slashContextApplies("session-a", undefined)).toBe(false)
})

test("every command in the help guide is completable", () => {
  const completable = new Set(slashCommands.map((command) => command.name))
  const documented = helpItems
    .flatMap(({ command }) => command.split(/[·,]/))
    .map((part) => part.trim().split(" ").filter((word) => !/[<|]/.test(word)).join(" "))
    .filter((part) => part.startsWith("/") && part !== "/?")
  for (const command of documented) expect(completable.has(command)).toBe(true)
})
