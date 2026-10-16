import { describe, expect, test } from "bun:test"
import {
  applyComposerReadlineKey,
  emptyComposerReadlineState,
  rememberReadlineSubmit,
} from "./composer-readline"

describe("applyComposerReadlineKey", () => {
  test("recalls submitted lines with up/down when draft is empty", () => {
    let state = rememberReadlineSubmit(emptyComposerReadlineState(), "fix flaky auth")
    state = rememberReadlineSubmit(state, "ship the slice")

    const older = applyComposerReadlineKey(state, { name: "up" })
    expect(older.kind).toBe("apply")
    if (older.kind !== "apply") return
    expect(older.state.value).toBe("ship the slice")

    const olderStill = applyComposerReadlineKey(older.state, { name: "up" })
    expect(olderStill.kind).toBe("apply")
    if (olderStill.kind !== "apply") return
    expect(olderStill.state.value).toBe("fix flaky auth")

    const newer = applyComposerReadlineKey(olderStill.state, { name: "down" })
    expect(newer.kind).toBe("apply")
    if (newer.kind !== "apply") return
    expect(newer.state.value).toBe("ship the slice")
  })

  test("refuses ↑ history while the live draft is non-empty", () => {
    let state = rememberReadlineSubmit(emptyComposerReadlineState(), "prior")
    state = { ...state, value: "typing", cursor: 6 }
    expect(applyComposerReadlineKey(state, { name: "up" })).toEqual({ kind: "ignore" })
  })

  test("Ctrl+K kills forward into the ring; Alt+Y yanks it back", () => {
    let state = {
      ...emptyComposerReadlineState(),
      value: "hello world",
      cursor: 5,
    }
    const killed = applyComposerReadlineKey(state, { name: "k", ctrl: true })
    expect(killed.kind).toBe("apply")
    if (killed.kind !== "apply") return
    expect(killed.state.value).toBe("hello")
    expect(killed.state.killRing.entries.at(-1)).toBe(" world")

    state = { ...killed.state, value: "hi", cursor: 2 }
    const yanked = applyComposerReadlineKey(state, { name: "y", meta: true })
    expect(yanked.kind).toBe("apply")
    if (yanked.kind !== "apply") return
    expect(yanked.state.value).toBe("hi world")
  })

  test("Ctrl+W kills the previous word", () => {
    const state = {
      ...emptyComposerReadlineState(),
      value: "alpha beta",
      cursor: 10,
    }
    const result = applyComposerReadlineKey(state, { name: "w", ctrl: true })
    expect(result.kind).toBe("apply")
    if (result.kind !== "apply") return
    expect(result.state.value).toBe("alpha ")
    expect(result.state.killRing.entries.at(-1)).toBe("beta")
  })

  test("Ctrl+A / Ctrl+E jump to draft ends", () => {
    const state = {
      ...emptyComposerReadlineState(),
      value: "draft",
      cursor: 2,
    }
    const home = applyComposerReadlineKey(state, { name: "a", ctrl: true })
    expect(home.kind).toBe("apply")
    if (home.kind !== "apply") return
    expect(home.state.cursor).toBe(0)

    const end = applyComposerReadlineKey(home.state, { name: "e", ctrl: true })
    expect(end.kind).toBe("apply")
    if (end.kind !== "apply") return
    expect(end.state.cursor).toBe(5)
  })
})
