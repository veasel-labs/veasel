import { describe, expect, test } from "bun:test"
import {
  adjacentSettingsStep,
  credentialStepCopy,
  endpointHost,
  providerHasKnownEndpoint,
  settingsBackTarget,
  settingsPath,
  settingsProgress,
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
})
