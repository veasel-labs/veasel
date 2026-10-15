import { describe, expect, test } from "bun:test"
import { composerHeightForText, composerKeyBindings, composerMaxHeight } from "./composer-input"

describe("composerHeightForText", () => {
  test("stays one row for empty or single-line drafts", () => {
    expect(composerHeightForText("")).toBe(1)
    expect(composerHeightForText("hello")).toBe(1)
  })

  test("grows with explicit newlines and caps at composerMaxHeight", () => {
    expect(composerHeightForText("a\nb")).toBe(2)
    expect(composerHeightForText("a\nb\nc\nd\ne\nf\ng")).toBe(composerMaxHeight)
  })
})

describe("composerKeyBindings", () => {
  test("submits on Enter and inserts a newline on Shift+Enter, Ctrl+J, or Alt+Enter", () => {
    const action = (
      name: string,
      mods: { shift?: boolean; meta?: boolean; ctrl?: boolean } = {},
    ) =>
      composerKeyBindings.find(
        (binding) =>
          binding.name === name
          && Boolean(binding.shift) === Boolean(mods.shift)
          && Boolean(binding.meta) === Boolean(mods.meta)
          && Boolean(binding.ctrl) === Boolean(mods.ctrl),
      )?.action

    expect(action("return")).toBe("submit")
    expect(action("kpenter")).toBe("submit")
    expect(action("linefeed")).toBe("newline")
    expect(action("j", { ctrl: true })).toBe("newline")
    expect(action("return", { shift: true })).toBe("newline")
    expect(action("return", { ctrl: true })).toBe("newline")
    expect(action("return", { meta: true })).toBe("newline")
  })
})
