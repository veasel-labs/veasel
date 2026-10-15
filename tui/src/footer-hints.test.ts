import { expect, test } from "bun:test"
import { homeFooterHint, sessionFooterHint } from "./footer-hints"

test("home footer surfaces the discovery slash commands", () => {
  for (const command of ["/connect", "/skills", "/mcp", "/theme"]) {
    expect(homeFooterHint).toContain(command)
  }
  expect(homeFooterHint).toContain("n new")
  expect(homeFooterHint).toContain("j/k")
  expect(homeFooterHint).toContain("Home/End")
  expect(homeFooterHint).toContain("q quit")
  expect(homeFooterHint.length).toBeLessThanOrEqual(72)
})

test("session footer surfaces reviews and the same discovery commands", () => {
  for (const command of ["/skills", "/plugins", "/mcp", "/theme", "/map"]) {
    expect(sessionFooterHint).toContain(command)
  }
  expect(sessionFooterHint).toContain("Ctrl+R reviews")
  expect(sessionFooterHint).toContain("Esc home")
  expect(sessionFooterHint).toContain("/ commands")
})
