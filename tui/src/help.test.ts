import { describe, expect, test } from "bun:test"
import { helpItems, isModelSettingsCommand, renderHelp, unknownSlashCommand } from "./help"

describe("TUI quick help", () => {
  test("documents every command family and the review-before-effect safety model", () => {
    const help = renderHelp()

    expect(help).toContain("/mcp call show|approve|reject <id>")
    expect(help).toContain("/patches · /patch show|approve|reject <id>")
    expect(help).toContain("/commands · /command show|approve|reject <id>")
    expect(help).toContain("home · j/k · Enter · n")
    expect(help).toContain("keeps the selection on screen")
    expect(help).toContain("lines added and removed")
    expect(help).toContain("sandbox warning stays above")
    expect(help).toContain("/history older")
    expect(help).toContain("s · /models")
    expect(help).toContain("Files go to your provider.")
    expect(help).toContain("without a sandbox")
    expect(helpItems.length).toBeGreaterThan(5)
  })

  test("formats a single reusable guide with non-empty command descriptions", () => {
    expect(helpItems.every(({ command, description }) => command.length > 0 && description.length > 0)).toBe(true)
    expect(renderHelp().split("\n").length).toBeGreaterThan(helpItems.length)
  })

  test("keeps the small-screen guide concise and points to full syntax", () => {
    const help = renderHelp(true)

    expect(help).toContain("/help advanced")
    expect(help).toContain("Files go to your provider.")
    expect(help.split("\n")).toHaveLength(7)
  })

  test("identifies only messages that begin with an unknown slash command", () => {
    expect(unknownSlashCommand("/wat")).toBe("/wat")
    expect(unknownSlashCommand("  /not-real  ")).toBe("/not-real")
    expect(unknownSlashCommand("Please inspect ./src/main.v")).toBeUndefined()
  })

  test("opens model settings only for the explicit session command", () => {
    expect(isModelSettingsCommand("/models")).toBe(true)
    expect(isModelSettingsCommand("  /models ")).toBe(true)
    expect(isModelSettingsCommand("please inspect this session")).toBe(false)
  })
})
