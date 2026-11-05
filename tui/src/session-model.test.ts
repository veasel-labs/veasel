import { expect, test } from "bun:test"
import {
  formatActiveModelLabel,
  formatListeningStatus,
  needsModelSetup,
  NO_MODEL_SETUP_GUIDANCE,
} from "./session-model"

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

test("flags only an explicit backend not-ready verdict for setup guidance", () => {
  expect(needsModelSetup({ model_ready: false })).toBe(true)
  expect(needsModelSetup({ model_ready: true })).toBe(false)
  // Older backends omit the field; never warn on absence of evidence.
  expect(needsModelSetup({})).toBe(false)
  expect(NO_MODEL_SETUP_GUIDANCE).toContain("/connect")
})
