import { describe, expect, test } from "bun:test"
import {
  contentHasThinking,
  isThinkingExpanded,
  latestThinkingId,
  splitThinkingParts,
  thinkingHeader,
  thinkingToggleShortcut,
  toggleThinkingExpanded,
} from "./thinking-blocks"

describe("thinking blocks", () => {
  test("documents Ctrl+H toggle shortcut", () => {
    expect(thinkingToggleShortcut.label).toBe("Ctrl+H")
    expect(thinkingToggleShortcut.ctrl).toBe(true)
  })

  test("splits fenced thinking from surrounding text", () => {
    const parts = splitThinkingParts(
      "intro\n```thinking\nhmm secrets\n```\nvisible answer",
      "m0",
    )
    expect(parts).toEqual([
      { type: "text", text: "intro\n" },
      { type: "thinking", text: "hmm secrets", id: "m0-thinking-0" },
      { type: "text", text: "\nvisible answer" },
    ])
    expect(contentHasThinking("```thinking\nx\n```")).toBe(true)
    expect(contentHasThinking("plain")).toBe(false)
  })

  test("headers collapse with preview and expand cleanly", () => {
    expect(thinkingHeader(false, "long reasoning about the patch")).toContain("▸ thinking")
    expect(thinkingHeader(false, "long reasoning about the patch")).toContain("long reasoning")
    expect(thinkingHeader(true, "body")).toBe("▾ thinking")
  })

  test("toggles expanded map and finds latest id", () => {
    expect(isThinkingExpanded({}, "a")).toBe(false)
    const opened = toggleThinkingExpanded({}, "a")
    expect(isThinkingExpanded(opened, "a")).toBe(true)
    expect(toggleThinkingExpanded(opened, "a")["a"]).toBe(false)

    expect(
      latestThinkingId([
        { role: "user", content: "hi" },
        { role: "assistant", content: "```thinking\nold\n```\nok" },
        { role: "assistant", content: "```thinking\nnew\n```\ndone" },
      ]),
    ).toBe("m2-thinking-0")
  })
})
