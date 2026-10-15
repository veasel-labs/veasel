import { expect, test } from "bun:test"
import { formatSettingsLoadError, formatSettingsSaveError } from "./settings-errors"

test("save errors stay actionable and keep the wizard in mind", () => {
  expect(formatSettingsSaveError("unauthorized api key")).toContain("✖ could not save")
  expect(formatSettingsSaveError("unauthorized api key")).toContain("Check the API key")
  expect(formatSettingsSaveError("invalid endpoint host")).toContain("Ctrl+U")
  expect(formatSettingsSaveError("unknown model id")).toContain("Pick another model")
  expect(formatSettingsSaveError("")).toContain("settings were rejected")
  expect(formatSettingsLoadError("HTTP 503")).toBe("✖ could not load model settings · HTTP 503")
})
