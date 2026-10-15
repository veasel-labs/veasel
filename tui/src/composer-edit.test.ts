import { describe, expect, test } from "bun:test"
import { composerLineCursor, killWordBackward } from "./composer-edit"

describe("killWordBackward", () => {
  test("deletes the word before the cursor and keeps the rest", () => {
    expect(killWordBackward("hello world", 11)).toEqual({ value: "hello ", cursor: 6 })
    expect(killWordBackward("hello world", 5)).toEqual({ value: " world", cursor: 0 })
    expect(killWordBackward("hello  world", 7)).toEqual({ value: "world", cursor: 0 })
  })

  test("is a no-op at the start and on empty drafts", () => {
    expect(killWordBackward("", 0)).toEqual({ value: "", cursor: 0 })
    expect(killWordBackward("hello", 0)).toEqual({ value: "hello", cursor: 0 })
  })

  test("treats accented Latin letters as part of the word", () => {
    expect(killWordBackward("café latte", 4)).toEqual({ value: " latte", cursor: 0 })
    expect(killWordBackward("café latte", 10)).toEqual({ value: "café ", cursor: 5 })
  })
})

describe("composerLineCursor", () => {
  test("jumps to the start or end of the draft", () => {
    expect(composerLineCursor("hello", "home")).toBe(0)
    expect(composerLineCursor("hello", "end")).toBe(5)
    expect(composerLineCursor("", "end")).toBe(0)
  })
})
