import { describe, expect, test } from "bun:test"
import {
  filterSelectOptions,
  fuzzyScore,
  groupSelectOptions,
  moveSelectIndex,
  type DialogSelectOption,
} from "./ui/dialog-select-filter"

const sample: DialogSelectOption[] = [
  { title: "Mint", value: "mint", category: "Builtin", searchText: "green" },
  { title: "Ember", value: "ember", category: "Builtin", searchText: "warm" },
  { title: "Custom dark", value: "custom", category: "Custom", description: "user theme" },
  { title: "Disabled", value: "nope", category: "Builtin", disabled: true },
]

describe("DialogSelect filter helpers", () => {
  test("fuzzyScore prefers exact and prefix matches", () => {
    expect(fuzzyScore("mint", "mint")).toBeGreaterThan(fuzzyScore("minty", "mint"))
    expect(fuzzyScore("minty", "mint")).toBeGreaterThan(fuzzyScore("xmint", "mint"))
    expect(fuzzyScore("ember", "zzz")).toBe(-1)
  })

  test("filterSelectOptions skips disabled and ranks title hits", () => {
    expect(filterSelectOptions(sample, "").map((item) => item.value)).toEqual([
      "mint",
      "ember",
      "custom",
    ])
    expect(filterSelectOptions(sample, "mint").map((item) => item.value)).toEqual(["mint"])
    expect(filterSelectOptions(sample, "warm").map((item) => item.value)).toEqual(["ember"])
    expect(filterSelectOptions(sample, "custom").map((item) => item.value)).toEqual(["custom"])
    expect(filterSelectOptions(sample, "disabled")).toEqual([])
  })

  test("groupSelectOptions preserves categories unless flat", () => {
    const enabled = filterSelectOptions(sample, "")
    expect(groupSelectOptions(enabled)).toEqual([
      [
        "Builtin",
        [
          { title: "Mint", value: "mint", category: "Builtin", searchText: "green" },
          { title: "Ember", value: "ember", category: "Builtin", searchText: "warm" },
        ],
      ],
      [
        "Custom",
        [{ title: "Custom dark", value: "custom", category: "Custom", description: "user theme" }],
      ],
    ])
    expect(groupSelectOptions(enabled, true)).toEqual([["", enabled]])
  })

  test("moveSelectIndex wraps", () => {
    expect(moveSelectIndex(0, 3, -1)).toBe(2)
    expect(moveSelectIndex(2, 3, 1)).toBe(0)
    expect(moveSelectIndex(1, 3, 1)).toBe(2)
  })
})
