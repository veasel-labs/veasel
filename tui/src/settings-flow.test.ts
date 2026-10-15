import { describe, expect, test } from "bun:test"
import {
  adjacentSettingsStep,
  credentialStepCopy,
  endpointHost,
  homeWorkspaceBlurb,
  providerHasKnownEndpoint,
  providerSwitchNote,
  settingsBackTarget,
  settingsFooterHint,
  settingsModeIntro,
  settingsPath,
  settingsProgress,
  settingsProviderStepPrompt,
  formatSettingsListStatus,
  moveSettingsListIndex,
} from "./settings-flow"

const openai = { base_url: "https://api.openai.com/v1", requires_api_key: true }
const ollama = { base_url: "http://127.0.0.1:11434/v1", requires_api_key: false }
const custom = { base_url: "", requires_api_key: true }

describe("provider setup path", () => {
  test("uses a catalog endpoint and asks only for a key and a model", () => {
    expect(providerHasKnownEndpoint(openai)).toBe(true)
    expect(settingsPath(openai)).toEqual([0, 2, 3])
    expect(endpointHost(openai.base_url)).toBe("api.openai.com")
  })

  test("skips the key when the provider does not need one", () => {
    expect(settingsPath(ollama)).toEqual([0, 3])
  })

  test("asks for an endpoint only when Veasel does not already know one", () => {
    expect(providerHasKnownEndpoint(custom)).toBe(false)
    expect(settingsPath(custom)).toEqual([0, 1, 2, 3])
    const cloudflare = {
      base_url: "https://api.cloudflare.com/client/v4/accounts/YOUR_ACCOUNT_ID/ai/v1",
      requires_api_key: true,
    }
    expect(providerHasKnownEndpoint(cloudflare)).toBe(false)
    expect(settingsPath(cloudflare)[1]).toBe(1)
  })

  test("keeps an advanced endpoint override available", () => {
    expect(settingsPath(openai, { editEndpoint: true })).toEqual([0, 1, 2, 3])
  })

  test("keeps the output budget available without putting it on the default path", () => {
    expect(settingsPath(openai, { editBudget: true })).toEqual([0, 2, 3, 4])
  })

  test("sends back from an endpoint side trip to the step that opened it", () => {
    const path = settingsPath(openai, { editEndpoint: true })
    expect(settingsBackTarget(path, 1, 2)).toEqual({ step: 2, cancelDetour: true })
    expect(settingsBackTarget(path, 1, undefined)).toEqual({ step: 0, cancelDetour: false })
  })

  test("moves only through the steps the user will see", () => {
    const path = settingsPath(openai)
    expect(adjacentSettingsStep(path, 0, 1)).toBe(2)
    expect(adjacentSettingsStep(path, 2, -1)).toBe(0)
    expect(adjacentSettingsStep(path, 3, 1)).toBe(3)
    expect(settingsProgress(path, 2)).toEqual({ index: 2, total: 3 })
  })

  test("treats saved keys as the primary path and env as an optional alternative", () => {
    const copy = credentialStepCopy({ apiKeySaved: false, environmentKey: "OPENAI_API_KEY" })
    expect(copy.prompt).toContain("Paste your API key")
    expect(copy.prompt).toContain("saves it for this provider")
    expect(copy.hint).toContain("Enter keeps an already-saved key")
    expect(copy.hint).toContain("!clear")
    expect(copy.hint).toContain("Or set OPENAI_API_KEY on the server process")
    expect(copy.hint).not.toContain("instead of saving a key")
    expect(credentialStepCopy({ apiKeySaved: true }).hint).toContain("A key is already saved")
  })

  test("distinguishes quick connect from full provider settings", () => {
    expect(settingsModeIntro("connect")).toContain("Quick connect")
    expect(settingsModeIntro("models")).toContain("Ctrl+O")
    expect(settingsProviderStepPrompt("connect")).toContain("Tab cycles")
    expect(providerSwitchNote("openai", "openai", "OpenAI")).toBe("")
    expect(providerSwitchNote("openai", "anthropic", "Anthropic")).toContain("Switching from openai → Anthropic")
    expect(settingsFooterHint(0, false, false)).toContain("Tab")
    expect(settingsFooterHint(0, false, false)).toContain("j/k")
    expect(settingsFooterHint(0, false, false)).toContain("1-9")
    expect(settingsFooterHint(0, false, false)).toContain("Home/End")
    expect(settingsFooterHint(0, false, false)).toContain("Ctrl+L")
    expect(settingsFooterHint(3, false, false)).toContain("j/k")
    expect(settingsFooterHint(3, false, false)).toContain("1-9")
    expect(settingsFooterHint(3, false, false)).toContain("Ctrl+L")
    expect(settingsFooterHint(2, true, true)).toContain("Ctrl+U endpoint")
    expect(homeWorkspaceBlurb({ providersConfigured: false })).toContain("/connect")
    expect(homeWorkspaceBlurb({ providersConfigured: true, modelLabel: "openai/gpt-5" })).toContain("Active model · openai/gpt-5")
    expect(moveSettingsListIndex(4, 10, "up")).toBe(3)
    expect(moveSettingsListIndex(4, 10, "down")).toBe(5)
    expect(moveSettingsListIndex(0, 10, "up")).toBe(0)
    expect(moveSettingsListIndex(9, 10, "down")).toBe(9)
    expect(moveSettingsListIndex(4, 10, "home")).toBe(0)
    expect(moveSettingsListIndex(4, 10, "end")).toBe(9)
    expect(moveSettingsListIndex(4, 10, "pageup", 3)).toBe(1)
    expect(moveSettingsListIndex(4, 10, "pagedown", 3)).toBe(7)
    expect(formatSettingsListStatus(0, 13, "All 13/13")).toBe("● All 13/13  ·  selected 1 of 13")
    expect(formatSettingsListStatus(12, 13, "Models 4/13")).toBe("● Models 4/13  ·  selected 13 of 13")
    expect(formatSettingsListStatus(0, 0, "All 0/13")).toBe("● All 0/13  ·  none")
  })
})
