import { describe, expect, test } from "bun:test"
import { helpItems } from "./help"
import {
  completeSlashCommand,
  moveSuggestion,
  runsOnAccept,
  slashCommands,
  slashSuggestions,
  suggestionWindow,
} from "./slash-commands"

const names = (input: string) => slashSuggestions(input).map((command) => command.name)

describe("slashSuggestions", () => {
  test("lists every command for a bare slash and nothing for plain prompts", () => {
    expect(names("/")).toHaveLength(slashCommands.length)
    expect(names("")).toEqual([])
    expect(names("explain /mcp")).toEqual([])
  })

  test("filters by prefix and ranks an exact match first", () => {
    expect(names("/pa")).toEqual(["/patches", "/patch"])
    expect(names("/patch")[0]).toBe("/patch")
    expect(names("/mcp")[0]).toBe("/mcp")
    expect(names("/mcp c")).toEqual(["/mcp calls", "/mcp call"])
  })

  test("is case-insensitive and tolerates repeated spaces", () => {
    expect(names("/HIST")).toEqual(["/history older"])
    expect(names("/mcp   tr")).toEqual(["/mcp trust"])
  })

  test("falls back to substring matches after prefix matches", () => {
    expect(names("/older")).toEqual(["/history older"])
    expect(names("/trust")).toEqual(["/mcp trust", "/mcp untrust"])
  })

  test("stops suggesting once arguments are being typed", () => {
    expect(names("/patch ")).toEqual([])
    expect(names("/mcp call show 1234")).toEqual([])
    expect(names("/skill on review/lint")).toEqual([])
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
})

test("every command in the help guide is completable", () => {
  const completable = new Set(slashCommands.map((command) => command.name))
  const documented = helpItems
    .flatMap(({ command }) => command.split(/[·,]/))
    .map((part) => part.trim().split(" ").filter((word) => !/[<|]/.test(word)).join(" "))
    .filter((part) => part.startsWith("/") && part !== "/?")
  for (const command of documented) expect(completable.has(command)).toBe(true)
})
