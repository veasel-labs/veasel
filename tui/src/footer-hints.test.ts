import { expect, test } from "bun:test"
import {
  homeFilterFooterHint,
  homeFooterForFilter,
  homeFooterHint,
  sessionFooterForMode,
  sessionFooterHint,
  sessionPathFooterHint,
  sessionReviewFooterHint,
  sessionReviewPatchFooterHint,
  sessionSlashFooterHint,
  sessionStreamingFooterHint,
} from "./footer-hints"

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
  expect(sessionFooterHint).toContain("Ctrl+U/W/Y")
  expect(sessionFooterHint).toContain("↑")
  expect(sessionFooterHint).toContain("Esc")
  expect(sessionFooterHint).toContain("@") // workspace path autocomplete
  expect(sessionFooterHint).toContain("S-↵") // Shift+Enter multiline
  expect(sessionFooterHint).toContain("?") // empty-composer ? opens /help
  expect(sessionFooterHint).not.toContain("/theme") // /theme stays in /help; footer budget prefers @ / S-↵
  expect(sessionFooterHint).not.toContain("Ctrl+R") // Ctrl+R stays in /help; footer budget prefers @ / S-↵
  expect(sessionFooterHint).not.toContain("Pg") // PgUp/PgDn stay in /help; footer budget prefers @ / S-↵
  expect(sessionFooterHint.length).toBeLessThanOrEqual(72)
})

test("sessionFooterForMode swaps contextual chrome without exceeding the budget", () => {
  expect(sessionFooterForMode()).toBe(sessionFooterHint)
  expect(sessionFooterForMode({ pathComplete: true })).toBe(sessionPathFooterHint)
  expect(sessionFooterForMode({ slashComplete: true })).toBe(sessionSlashFooterHint)
  expect(sessionFooterForMode({ reviewPending: true, reviewKind: "command" })).toBe(sessionReviewFooterHint)
  expect(sessionFooterForMode({ reviewPending: true, reviewKind: "patch" })).toBe(sessionReviewPatchFooterHint)
  expect(sessionFooterForMode({ streaming: true })).toBe(sessionStreamingFooterHint)
  // Autocomplete wins over review/stream so Tab/Esc stay obvious while the menu is open.
  expect(sessionFooterForMode({
    pathComplete: true,
    reviewPending: true,
    streaming: true,
  })).toBe(sessionPathFooterHint)
  expect(sessionFooterForMode({
    slashComplete: true,
    reviewPending: true,
  })).toBe(sessionSlashFooterHint)
  // Review overlay beats streaming so approve keys stay on the always-visible row.
  expect(sessionFooterForMode({
    reviewPending: true,
    reviewKind: "mcp",
    streaming: true,
  })).toBe(sessionReviewFooterHint)
  for (const hint of [
    sessionPathFooterHint,
    sessionSlashFooterHint,
    sessionReviewFooterHint,
    sessionReviewPatchFooterHint,
    sessionStreamingFooterHint,
  ]) {
    expect(hint.length).toBeLessThanOrEqual(72)
  }
  expect(sessionPathFooterHint).toContain("@ paths")
  expect(sessionSlashFooterHint).toContain("Tab/Enter")
  expect(sessionReviewFooterHint).toContain("a/x")
  expect(sessionReviewPatchFooterHint).toContain("{/}")
  expect(sessionReviewPatchFooterHint).toContain("v")
  expect(sessionStreamingFooterHint).toContain("Esc cancel")
  expect(sessionStreamingFooterHint).toContain("End follow")
})
