import { describe, expect, test } from "bun:test"
import {
  activeReviewIndex,
  moveActiveReviewIndex,
  pendingReviewsOfKind,
  reviewHotkey,
  reviewHotkeyHint,
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

  test("maps approve, reject, bulk approve, and neighbor navigation", () => {
    const ctx = { composerEmpty: true, review: pendingPatch }
    expect(reviewHotkey({ name: "a", ctrl: false, meta: false }, ctx)).toEqual({ action: "approve" })
    expect(reviewHotkey({ name: "a", ctrl: false, meta: false, shift: true }, ctx)).toEqual({ action: "approveAll" })
    expect(reviewHotkey({ name: "x", ctrl: false, meta: false }, ctx)).toEqual({ action: "reject" })
    expect(reviewHotkey({ name: "]", ctrl: false, meta: false }, ctx)).toEqual({ action: "next" })
    expect(reviewHotkey({ name: "[", ctrl: false, meta: false }, ctx)).toEqual({ action: "prev" })
    expect(reviewHotkey({ name: "n", ctrl: false, meta: false }, ctx)).toEqual({ action: "next" })
    expect(reviewHotkey({ name: "p", ctrl: false, meta: false }, ctx)).toEqual({ action: "prev" })
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

  test("keeps the hotkey hint on the first screen", () => {
    const notice = "REVIEW WORKSPACE EDIT  /  PENDING\nsrc/main.v"
    const withHint = withReviewHotkeyHint(notice, pendingPatch)
    expect(withHint.startsWith("REVIEW WORKSPACE EDIT  /  PENDING\na approve · A all same kind")).toBe(true)
    expect(withReviewHotkeyHint(withHint, pendingPatch)).toBe(withHint)
    expect(withReviewHotkeyHint(notice, undefined)).toBe(notice)
  })
})
