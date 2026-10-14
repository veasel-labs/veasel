import { describe, expect, test } from "bun:test"
import { shouldQuitOnKey } from "./keyboard"

const q = { name: "q", ctrl: false, meta: false }
const idle = { creatingSession: false, composerActive: false }

describe("shouldQuitOnKey", () => {
  test("quits on q from the home screen", () => {
    expect(shouldQuitOnKey(q, idle)).toBe(true)
  })

  test("keeps q as text while the chat composer is active", () => {
    expect(shouldQuitOnKey(q, { ...idle, composerActive: true })).toBe(false)
  })

  test("keeps q as text while naming a new session", () => {
    expect(shouldQuitOnKey(q, { ...idle, creatingSession: true })).toBe(false)
  })

  test("ignores other keys and modified q", () => {
    expect(shouldQuitOnKey({ ...q, name: "w" }, idle)).toBe(false)
    expect(shouldQuitOnKey({ ...q, ctrl: true }, idle)).toBe(false)
    expect(shouldQuitOnKey({ ...q, meta: true }, idle)).toBe(false)
  })
})
