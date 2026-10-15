import { expect, test } from "bun:test"
import { formatActiveModelLabel, formatListeningStatus } from "./session-model"

test("formats provider/model for the listening status", () => {
  expect(formatActiveModelLabel({})).toBeUndefined()
  expect(formatActiveModelLabel({ active_provider: "openai" })).toBe("openai")
  expect(
    formatActiveModelLabel({
      active_provider: "openai",
      profiles: { openai: { model: "gpt-5" } },
    }),
  ).toBe("openai/gpt-5")
  expect(formatListeningStatus()).toBe("● connected  ·  listening for activity")
  expect(formatListeningStatus("openai/gpt-5")).toBe(
    "● connected  ·  openai/gpt-5  ·  listening for activity",
  )
})
