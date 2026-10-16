import { describe, expect, test } from "bun:test"
import {
  acceptComposerAutocomplete,
  demoComposerSkills,
  moveComposerAutocomplete,
  resolveComposerAutocomplete,
} from "./composer-autocomplete"

describe("Solid composer autocomplete", () => {
  test("resolves slash suggestions for /he", () => {
    const menu = resolveComposerAutocomplete({ value: "/he", cursor: 3 })
    expect(menu?.kind).toBe("slash")
    expect(menu?.items.some((item) => item.name === "/help")).toBe(true)
  })

  test("resolves @ path suggestions from a stub workspace list", () => {
    const menu = resolveComposerAutocomplete({
      value: "see @src/ma",
      cursor: 11,
      workspaceRoot: "/tmp/ws",
      listPaths: () => ["src/main.ts", "src/map.ts", "README.md"],
    })
    expect(menu?.kind).toBe("path")
    expect(menu?.items.map((item) => item.name)).toContain("@src/main.ts")
  })

  test("resolves $ skill suggestions from the demo catalog", () => {
    const menu = resolveComposerAutocomplete({
      value: "run $demo/co",
      cursor: 12,
      skills: demoComposerSkills(),
    })
    expect(menu?.kind).toBe("skill")
    expect(menu?.items.some((item) => item.name === "$demo/code-review")).toBe(true)
  })

  test("accepts path mention with trailing space", () => {
    const next = acceptComposerAutocomplete({
      value: "@src/ma",
      cursor: 7,
      selected: 0,
      listPaths: () => ["src/main.ts"],
    })
    expect(next?.value).toBe("@src/main.ts ")
  })

  test("accepts slash that needs more args without submit", () => {
    const next = acceptComposerAutocomplete({
      value: "/theme",
      cursor: 6,
      selected: 0,
    })
    expect(next?.value.startsWith("/theme")).toBe(true)
    expect(next?.submit).toBeUndefined()
  })

  test("move selection wraps", () => {
    expect(moveComposerAutocomplete(0, 1, 3)).toBe(1)
    expect(moveComposerAutocomplete(0, -1, 3)).toBe(2)
  })

  test("dismissed draft hides the menu", () => {
    const menu = resolveComposerAutocomplete({
      value: "/he",
      cursor: 3,
      dismissed: { kind: "slash", value: "/he" },
    })
    expect(menu).toBeUndefined()
  })
})
