import { expect, test } from "bun:test"
import {
  formatProviderConnectionError,
  formatSettingsLoadError,
  formatSettingsSaveError,
} from "./settings-errors"

test("save errors stay actionable and keep the wizard in mind", () => {
  expect(formatSettingsSaveError("unauthorized api key")).toContain("✖ could not save")
  expect(formatSettingsSaveError("unauthorized api key")).toContain("Check the API key")
  expect(formatSettingsSaveError("invalid endpoint host")).toContain("Ctrl+U")
  expect(formatSettingsSaveError("unknown model id")).toContain("Pick another model")
  expect(formatSettingsSaveError("")).toContain("settings were rejected")
  expect(formatSettingsLoadError("HTTP 503")).toBe("✖ could not load model settings · HTTP 503")
})

test("OpenCode API-key rejection explains how to replace an expired key", () => {
  const message = formatProviderConnectionError(
    "opencode-go",
    "model catalog endpoint returned HTTP 401",
  )
  expect(message).toContain("create a new key in OpenCode Console")
  expect(message).toContain("signing in again will not renew it")
})

test("OpenCode Go access and rate-limit failures point to the next step", () => {
  expect(formatProviderConnectionError("opencode-go", "HTTP 403")).toContain(
    "Check your Go subscription",
  )
  expect(formatProviderConnectionError("opencode", "HTTP 429")).toContain(
    "Check your usage limits, wait, then retry",
  )
})

test("other providers keep their existing discovery error", () => {
  expect(formatProviderConnectionError("anthropic", "HTTP 401")).toBe("HTTP 401")
})
