import { expect, test } from "bun:test"
import { homeFooterHint, sessionFooterHint } from "./footer-hints"

test("home footer surfaces the discovery slash commands", () => {
  for (const command of ["/connect", "/skills", "/mcp", "/theme"]) {
    expect(homeFooterHint).toContain(command)
  }
  expect(homeFooterHint).toContain("n new")
  expect(homeFooterHint).toContain("j/k")
  expect(homeFooterHint).toContain("type")
  expect(homeFooterHint).toContain("q quit")
  expect(homeFooterHint).not.toContain("Home/End") // Home/End stays in /help; footer budget prefers type-to-filter
  expect(homeFooterHint.length).toBeLessThanOrEqual(72)
})

test("session footer surfaces reviews and the same discovery commands", () => {
  for (const command of ["/skills", "/mcp", "/theme", "/map"]) {
    expect(sessionFooterHint).toContain(command)
  }
  expect(sessionFooterHint).toContain("Ctrl+U")
  expect(sessionFooterHint).toContain("Ctrl+R")
  expect(sessionFooterHint).toContain("Ctrl+Y")
  expect(sessionFooterHint).toContain("↑")
  expect(sessionFooterHint).toContain("Esc")
  expect(sessionFooterHint).toContain("Pg")
  expect(sessionFooterHint.length).toBeLessThanOrEqual(72)
})
