import { describe, expect, test } from "bun:test"
import { helpItems, renderHelp, unknownSlashCommand } from "./help"

describe("TUI quick help", () => {
  test("documents every command family and the review-before-effect safety model", () => {
    const help = renderHelp()

    expect(help).toContain("/mcp call show|approve|reject <id>")
    expect(help).toContain("/patches · /patch show|approve|reject <id>")
    expect(help).toContain("/commands · /command show|approve|reject <id>")
    expect(help).toContain("/history older")
    expect(help).toContain("without a sandbox")
    expect(helpItems.length).toBeGreaterThan(5)
  })

  test("formats a single reusable guide with non-empty command descriptions", () => {
    expect(helpItems.every(({ command, description }) => command.startsWith("/") && description.length > 0)).toBe(true)
    expect(renderHelp().split("\n").length).toBeGreaterThan(helpItems.length)
  })

  test("identifies only messages that begin with an unknown slash command", () => {
    expect(unknownSlashCommand("/wat")).toBe("/wat")
    expect(unknownSlashCommand("  /not-real  ")).toBe("/not-real")
    expect(unknownSlashCommand("Please inspect ./src/main.v")).toBeUndefined()
  })
})
