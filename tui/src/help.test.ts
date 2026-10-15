import { describe, expect, test } from "bun:test"
import { helpItems, isConnectCommand, isModelSettingsCommand, renderHelp, unknownSlashCommand } from "./help"

describe("TUI quick help", () => {
  test("documents every command family and the review-before-effect safety model", () => {
    const help = renderHelp()

    expect(help).toContain("/mcp call show|approve|reject <id>")
    expect(help).toContain("/patches · /patch show|approve|reject <id>")
    expect(help).toContain("/commands · /command show|approve|reject <id>")
    expect(help).toContain("home · j/k · g/G · 1-9 · type · Home/End · PgUp/PgDn · Enter · n")
    expect(help).toContain("press g/G for first/last when no filter is active")
    expect(help).toContain("press 1-9 to jump to the Nth visible session")
    expect(help).toContain("the sidebar labels those slots")
    expect(help).toContain("the status line says filter and which match is focused")
    expect(help).toContain("type to filter by title or directory")
    expect(help).toContain("streaming below · End follows")
    expect(help).toContain("scrolled · End follows")
    expect(help).toContain("Ctrl+U clears the composer draft")
    expect(help).toContain("Ctrl+W deletes the word before the cursor")
    expect(help).toContain("Ctrl+K deletes from the cursor to the end")
    expect(help).toContain("Ctrl+A / Ctrl+E jump to the start or end of the draft")
    expect(help).toContain("it never clears the composer")
    expect(help).toContain("Selected N of M")
    expect(help).toContain("keeps the selection on screen")
    expect(help).toContain("lines added and removed")
    expect(help).toContain("sandbox warning stays above")
    expect(help).toContain("decision stays above the arguments")
    expect(help).toContain("/history older")
    expect(help).toContain("/usage")
    expect(help).toContain("provider-reported token totals")
    expect(help).toContain("/map")
    expect(help).toContain("extractive workspace repository map")
    expect(help).toContain("/theme")
    expect(help).toContain("/plugins · /plugin add · /plugin remove")
    expect(help).toContain("/mcp add")
    expect(help).toContain("/mcp remove · /mcp enable · /mcp disable")
    expect(help).toContain("/mcp credentials · /mcp credential set|remove")
    expect(help).toContain("/mcp oauth authorize|complete")
    expect(help).toContain("s · /models")
    expect(help).toContain("/connect")
    expect(help).toContain("Ctrl+L clears the filter")
    expect(help).toContain("j/k move or press 1-9 to jump when the filter is empty")
    expect(help).toContain("same j/k · 1-9 · Home/End · Pg · Ctrl+L filter keys")
    expect(help).toContain("Home/End and PgUp/PgDn jump the list")
    expect(help).toContain("selected N of M in plain text")
    expect(help).toContain("Quick connect")
    expect(help).toContain("Full provider settings cockpit")
    expect(help).toContain("Files go to your provider.")
    expect(help).toContain("Bubblewrap on Linux, Seatbelt on macOS, or AppContainer on Windows when available")
    expect(helpItems.length).toBeGreaterThan(5)
  })

  test("formats a single reusable guide with non-empty command descriptions", () => {
    expect(helpItems.every(({ command, description }) => command.length > 0 && description.length > 0)).toBe(true)
    expect(renderHelp().split("\n").length).toBeGreaterThan(helpItems.length)
  })

  test("keeps the small-screen guide concise and points to full syntax", () => {
    const help = renderHelp(true)

    expect(help).toContain("/help advanced")
    expect(help).toContain("/mcp credentials · /mcp oauth")
    expect(help).toContain("Named HTTP auth")
    expect(help).toContain("Files go to your provider.")
    expect(help.split("\n")).toHaveLength(8)
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

  test("opens connect only for the explicit session command", () => {
    expect(isConnectCommand("/connect")).toBe(true)
    expect(isConnectCommand("  /connect ")).toBe(true)
    expect(isConnectCommand("/models")).toBe(false)
    expect(isConnectCommand("please connect the provider")).toBe(false)
  })
})
