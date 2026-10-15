import { describe, expect, test } from "bun:test"
import {
  activeReviewIndex,
  moveActiveReviewIndex,
  pendingReviewsOfKind,
  resolveSelectedReviews,
  reviewHotkey,
  reviewHotkeyHint,
  reviewSelectionKey,
  toggleReviewSelection,
  withReviewHotkeyHint,
  type ActiveReview,
} from "./active-review"

const pendingPatch: ActiveReview = {
  kind: "patch",
  id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  pending: true,
}

describe("reviewHotkey", () => {
  test("ignores keys while the composer has text or the review is settled", () => {
    expect(reviewHotkey({ name: "a", ctrl: false, meta: false }, {
      composerEmpty: false,
      review: pendingPatch,
    })).toBeUndefined()
    expect(reviewHotkey({ name: "a", ctrl: false, meta: false }, {
      composerEmpty: true,
      review: { ...pendingPatch, pending: false },
    })).toBeUndefined()
  })

  test("maps approve, reject, bulk approve/reject, select, and neighbor navigation", () => {
    const ctx = { composerEmpty: true, review: pendingPatch }
    expect(reviewHotkey({ name: "a", ctrl: false, meta: false }, ctx)).toEqual({ action: "approve" })
    expect(reviewHotkey({ name: "a", ctrl: false, meta: false, shift: true }, ctx)).toEqual({ action: "approveAll" })
    expect(reviewHotkey({ name: "x", ctrl: false, meta: false }, ctx)).toEqual({ action: "reject" })
    expect(reviewHotkey({ name: "x", ctrl: false, meta: false, shift: true }, ctx)).toEqual({ action: "rejectAll" })
    expect(reviewHotkey({ name: "space", ctrl: false, meta: false }, ctx)).toEqual({ action: "toggleSelect" })
    expect(reviewHotkey({ name: " ", ctrl: false, meta: false }, ctx)).toEqual({ action: "toggleSelect" })
    expect(reviewHotkey({ name: "]", ctrl: false, meta: false }, ctx)).toEqual({ action: "next" })
    expect(reviewHotkey({ name: "[", ctrl: false, meta: false }, ctx)).toEqual({ action: "prev" })
    expect(reviewHotkey({ name: "n", ctrl: false, meta: false }, ctx)).toEqual({ action: "next" })
    expect(reviewHotkey({ name: "p", ctrl: false, meta: false }, ctx)).toEqual({ action: "prev" })
    expect(reviewHotkey({ name: "{", ctrl: false, meta: false }, ctx)).toEqual({ action: "hunkPrev" })
    expect(reviewHotkey({ name: "}", ctrl: false, meta: false }, ctx)).toEqual({ action: "hunkNext" })
    expect(reviewHotkey({ name: "{", ctrl: false, meta: false }, {
      composerEmpty: true,
      review: { kind: "command", id: pendingPatch.id, pending: true },
    })).toBeUndefined()
  })
})

describe("review multi-select", () => {
  test("toggles selection keys and resolves pending queue members", () => {
    const other: ActiveReview = {
      kind: "patch",
      id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      pending: true,
    }
    const key = reviewSelectionKey(pendingPatch)
    expect(key).toBe("patch:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
    let selected = toggleReviewSelection(new Set(), pendingPatch)
    expect(selected.has(key)).toBe(true)
    selected = toggleReviewSelection(selected, pendingPatch)
    expect(selected.has(key)).toBe(false)
    selected = toggleReviewSelection(new Set(), pendingPatch)
    selected = toggleReviewSelection(selected, other)
    expect(resolveSelectedReviews([pendingPatch, other], selected).map((item) => item.id)).toEqual([
      pendingPatch.id,
      other.id,
    ])
    expect(resolveSelectedReviews([pendingPatch], new Set(["command:nope"]))).toEqual([])
  })

  test("states the selection count in the hotkey hint", () => {
    expect(reviewHotkeyHint(pendingPatch)?.includes("Space select")).toBe(true)
    expect(reviewHotkeyHint(pendingPatch)).toContain("A/X all same kind")
    expect(reviewHotkeyHint(pendingPatch, { selectedCount: 2, currentSelected: true })).toContain(
      "● Space · 2 selected · a/x act on selection",
    )
  })
})

describe("pendingReviewsOfKind", () => {
  test("keeps only pending items of the requested family", () => {
    const queue: ActiveReview[] = [
      pendingPatch,
      { kind: "patch", id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", pending: true },
      { kind: "command", id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc", pending: true },
      { kind: "patch", id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", pending: false },
    ]
    expect(pendingReviewsOfKind(queue, "patch").map((item) => item.id)).toEqual([
      pendingPatch.id,
      "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    ])
    expect(pendingReviewsOfKind(queue, "mcp")).toEqual([])
  })
})

describe("review queue navigation", () => {
  test("wraps when moving across the ends of the queue", () => {
    expect(moveActiveReviewIndex(0, -1, 3)).toBe(2)
    expect(moveActiveReviewIndex(2, 1, 3)).toBe(0)
    expect(activeReviewIndex([pendingPatch], pendingPatch)).toBe(0)
    expect(activeReviewIndex([], pendingPatch)).toBe(0)
  })

  test("keeps the hotkey hint on the first screen and refreshes selection cues", () => {
    const notice = "REVIEW WORKSPACE EDIT  /  PENDING\nsrc/main.v"
    const withHint = withReviewHotkeyHint(notice, pendingPatch)
    expect(withHint.startsWith("REVIEW WORKSPACE EDIT  /  PENDING\na approve · A/X all same kind")).toBe(true)
    expect(withHint).toContain("Space select")
    expect(withReviewHotkeyHint(withHint, pendingPatch)).toBe(withHint)
    const refreshed = withReviewHotkeyHint(withHint, pendingPatch, { selectedCount: 1, currentSelected: true })
    expect(refreshed).toContain("1 selected")
    expect(refreshed).not.toContain("Space select\n")
    expect(withReviewHotkeyHint(notice, undefined)).toBe(notice)
  })
})
