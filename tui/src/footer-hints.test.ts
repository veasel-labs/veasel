import { expect, test } from "bun:test"
import { homeFilterFooterHint, homeFooterForFilter, homeFooterHint, sessionFooterHint } from "./footer-hints"

test("home footer surfaces the discovery slash commands", () => {
  for (const command of ["/connect", "/skills", "/mcp"]) {
    expect(homeFooterHint).toContain(command)
  }
  expect(homeFooterHint).toContain("n new")
  expect(homeFooterHint).toContain("j/k")
  expect(homeFooterHint).toContain("1-9")
  expect(homeFooterHint).toContain("type")
  expect(homeFooterHint).toContain("q quit")
  expect(homeFooterHint).not.toContain("Home/End") // Home/End stays in /help; footer budget prefers type-to-filter
  expect(homeFooterHint).not.toContain("/theme") // /theme stays in /help; footer budget prefers 1-9 jump
  expect(homeFooterHint.length).toBeLessThanOrEqual(72)
})

test("home filter footer names clear keys within the column budget", () => {
  expect(homeFooterForFilter("")).toBe(homeFooterHint)
  expect(homeFooterForFilter("Lane")).toBe(homeFilterFooterHint)
  expect(homeFilterFooterHint).toContain("Ctrl+L clear")
  expect(homeFilterFooterHint).toContain("Esc clear")
  expect(homeFilterFooterHint.length).toBeLessThanOrEqual(72)
})

test("session footer surfaces reviews and the same discovery commands", () => {
  for (const command of ["/skills", "/mcp", "/map"]) {
    expect(sessionFooterHint).toContain(command)
  }
  expect(sessionFooterHint).toContain("Ctrl+U")
  expect(sessionFooterHint).toContain("Ctrl+W")
  expect(sessionFooterHint).toContain("Ctrl+Y")
  expect(sessionFooterHint).toContain("↑")
  expect(sessionFooterHint).toContain("Esc")
  expect(sessionFooterHint).toContain("Pg")
  expect(sessionFooterHint).not.toContain("/theme") // /theme stays in /help; footer budget prefers Ctrl+W
  expect(sessionFooterHint).not.toContain("Ctrl+R") // Ctrl+R stays in /help; footer budget prefers Ctrl+W
  expect(sessionFooterHint.length).toBeLessThanOrEqual(72)
})
