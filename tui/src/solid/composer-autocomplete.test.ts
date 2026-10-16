import { describe, expect, test } from "bun:test"
import {
  acceptComposerAutocomplete,
  demoComposerSkills,
  jumpComposerAutocomplete,
  moveComposerAutocomplete,
  resolveComposerAutocomplete,
  windowedComposerItems,
} from "./composer-autocomplete"

describe("resolveComposerAutocomplete", () => {
  test("surfaces slash commands for a / draft", () => {
    const menu = resolveComposerAutocomplete({ value: "/he", cursor: 3 })
    expect(menu?.kind).toBe("slash")
    expect(menu?.items.some((item) => item.name === "/help")).toBe(true)
    expect(menu?.footer).toContain("Tab")
  })

  test("surfaces @ path suggestions from a fixture lister", () => {
    const menu = resolveComposerAutocomplete({
      value: "see @src/ma",
      cursor: 11,
      workspaceRoot: "/tmp/ws",
      listPaths: () => ["src/main.ts", "src/main.test.ts", "README.md"],
    })
    expect(menu?.kind).toBe("path")
    expect(menu?.items.map((item) => item.name)).toContain("@src/main.ts")
  })

  test("surfaces $ skill suggestions from the demo catalog", () => {
    const menu = resolveComposerAutocomplete({
      value: "$demo/code",
      cursor: 10,
      skills: demoComposerSkills(),
    })
    expect(menu?.kind).toBe("skill")
    expect(menu?.items[0]?.name).toBe("$demo/code-review")
  })

  test("honors Esc dismiss until the draft changes", () => {
    const value = "/he"
    const dismissed = resolveComposerAutocomplete({
      value,
      cursor: 3,
      dismissed: { kind: "slash", value },
    })
    expect(dismissed).toBeUndefined()
    const reopened = resolveComposerAutocomplete({
      value: "/hel",
      cursor: 4,
      dismissed: { kind: "slash", value },
    })
    expect(reopened?.kind).toBe("slash")
  })

  test("prefers @ over $ when both tokens could match", () => {
    // Path mention wins when the cursor is inside an @ token (classic priority).
    const menu = resolveComposerAutocomplete({
      value: "note @file $skill",
      cursor: 9,
      listPaths: () => ["file.ts"],
      skills: demoComposerSkills(),
    })
    expect(menu?.kind).toBe("path")
  })
})

describe("acceptComposerAutocomplete", () => {
  test("inserts a path mention with a trailing space", () => {
    const result = acceptComposerAutocomplete({
      value: "see @src/ma",
      cursor: 11,
      selected: 0,
      listPaths: () => ["src/main.ts"],
    })
    expect(result).toEqual({ value: "see @src/main.ts ", cursor: 17 })
  })

  test("inserts a skill mention with a trailing space", () => {
    const result = acceptComposerAutocomplete({
      value: "$demo/code",
      cursor: 10,
      selected: 0,
      skills: demoComposerSkills(),
    })
    expect(result).toEqual({ value: "$demo/code-review ", cursor: 18 })
  })

  test("completes a runnable slash command and flags submit", () => {
    const result = acceptComposerAutocomplete({
      value: "/he",
      cursor: 3,
      selected: 0,
    })
    expect(result?.value.startsWith("/help")).toBe(true)
    expect(result?.submit).toBe(true)
  })
})

describe("composer autocomplete navigation helpers", () => {
  test("move and jump wrap like the classic slash menu", () => {
    expect(moveComposerAutocomplete(0, -1, 3)).toBe(2)
    expect(moveComposerAutocomplete(2, 1, 3)).toBe(0)
    expect(jumpComposerAutocomplete(4, 10, "home")).toBe(0)
    expect(jumpComposerAutocomplete(1, 10, "end")).toBe(9)
  })

  test("windowedComposerItems slices to the visible window", () => {
    const menu = resolveComposerAutocomplete({ value: "/", cursor: 1, selected: 0 })
    expect(menu).toBeDefined()
    const visible = windowedComposerItems(menu!)
    expect(visible.length).toBeGreaterThan(0)
    expect(visible.length).toBeLessThanOrEqual(menu!.items.length)
  })
})
