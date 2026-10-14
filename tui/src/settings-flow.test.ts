import { describe, expect, test } from "bun:test"
import {
  adjacentSettingsStep,
  endpointHost,
  providerHasKnownEndpoint,
  settingsPath,
  settingsProgress,
} from "./settings-flow"

const openai = { base_url: "https://api.openai.com/v1", requires_api_key: true }
const ollama = { base_url: "http://127.0.0.1:11434/v1", requires_api_key: false }
const custom = { base_url: "", requires_api_key: true }

describe("provider setup path", () => {
  test("uses a catalog endpoint and asks only for a key, model, and budget", () => {
    expect(providerHasKnownEndpoint(openai)).toBe(true)
    expect(settingsPath(openai)).toEqual([0, 2, 3, 4])
    expect(endpointHost(openai.base_url)).toBe("api.openai.com")
  })

  test("skips the key when the provider does not need one", () => {
    expect(settingsPath(ollama)).toEqual([0, 3, 4])
  })

  test("asks for an endpoint only when Veasel does not already know one", () => {
    expect(providerHasKnownEndpoint(custom)).toBe(false)
    expect(settingsPath(custom)).toEqual([0, 1, 2, 3, 4])
    const cloudflare = {
      base_url: "https://api.cloudflare.com/client/v4/accounts/YOUR_ACCOUNT_ID/ai/v1",
      requires_api_key: true,
    }
    expect(providerHasKnownEndpoint(cloudflare)).toBe(false)
    expect(settingsPath(cloudflare)[1]).toBe(1)
  })

  test("keeps an advanced endpoint override available", () => {
    expect(settingsPath(openai, { editEndpoint: true })).toEqual([0, 1, 2, 3, 4])
  })

  test("moves only through the steps the user will see", () => {
    const path = settingsPath(openai)
    expect(adjacentSettingsStep(path, 0, 1)).toBe(2)
    expect(adjacentSettingsStep(path, 2, -1)).toBe(0)
    expect(adjacentSettingsStep(path, 4, 1)).toBe(4)
    expect(settingsProgress(path, 2)).toEqual({ index: 2, total: 4 })
  })
})
