import { describe, expect, test } from "bun:test"
import {
  composerLineCursor,
  killLineForward,
  killWordBackward,
  killWordForward,
  moveWordCursor,
  transposeChars,
} from "./composer-edit"

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

describe("killWordForward", () => {
  test("deletes from the cursor through the current or next word", () => {
    expect(killWordForward("hello world", 0)).toEqual({ value: " world", cursor: 0 })
    expect(killWordForward("hello world", 6)).toEqual({ value: "hello ", cursor: 6 })
    expect(killWordForward("hello  world", 5)).toEqual({ value: "hello", cursor: 5 })
  })

  test("is a no-op at the end and on empty drafts", () => {
    expect(killWordForward("", 0)).toEqual({ value: "", cursor: 0 })
    expect(killWordForward("hello", 5)).toEqual({ value: "hello", cursor: 5 })
  })

  test("treats accented Latin letters as part of the word", () => {
    expect(killWordForward("café latte", 0)).toEqual({ value: " latte", cursor: 0 })
    expect(killWordForward("café latte", 5)).toEqual({ value: "café ", cursor: 5 })
  })
})

describe("composerLineCursor", () => {
  test("jumps to the start or end of the draft", () => {
    expect(composerLineCursor("hello", "home")).toBe(0)
    expect(composerLineCursor("hello", "end")).toBe(5)
    expect(composerLineCursor("", "end")).toBe(0)
  })
})

describe("killLineForward", () => {
  test("deletes from the cursor to the end of the draft", () => {
    expect(killLineForward("hello world", 5)).toEqual({ value: "hello", cursor: 5 })
    expect(killLineForward("hello world", 0)).toEqual({ value: "", cursor: 0 })
    expect(killLineForward("hello", 5)).toEqual({ value: "hello", cursor: 5 })
  })
})

describe("moveWordCursor", () => {
  test("jumps backward and forward across whitespace-delimited words", () => {
    expect(moveWordCursor("one two three", 13, "backward")).toBe(8)
    expect(moveWordCursor("one two three", 8, "backward")).toBe(4)
    expect(moveWordCursor("one two three", 0, "forward")).toBe(4)
    expect(moveWordCursor("one two three", 4, "forward")).toBe(8)
    expect(moveWordCursor("one two three", 0, "backward")).toBe(0)
    expect(moveWordCursor("one two three", 13, "forward")).toBe(13)
  })
})

describe("transposeChars", () => {
  test("swaps the character before the cursor with the one at the cursor", () => {
    expect(transposeChars("ab", 1)).toEqual({ value: "ba", cursor: 2 })
    expect(transposeChars("abc", 2)).toEqual({ value: "acb", cursor: 3 })
  })

  test("at the end swaps the last two characters", () => {
    expect(transposeChars("ab", 2)).toEqual({ value: "ba", cursor: 2 })
    expect(transposeChars("abc", 3)).toEqual({ value: "acb", cursor: 3 })
  })

  test("is a no-op at the start or with fewer than two characters", () => {
    expect(transposeChars("ab", 0)).toEqual({ value: "ab", cursor: 0 })
    expect(transposeChars("a", 1)).toEqual({ value: "a", cursor: 1 })
    expect(transposeChars("", 0)).toEqual({ value: "", cursor: 0 })
  })
})
