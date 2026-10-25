import { describe, expect, test } from "bun:test"
import { parseOpenCodeGoApiKey } from "./opencode-auth"

describe("OpenCode Go credential import", () => {
  test("selects only the active OpenCode Go API key", () => {
    expect(parseOpenCodeGoApiKey(JSON.stringify([
      { integrationID: "openai", active: true, value: { type: "key", key: "ignore-me" } },
      { integrationID: "opencode-go", active: false, value: { type: "key", key: "stale" } },
      { integrationID: "opencode-go", active: true, value: { type: "key", key: "go-key" } },
    ]))).toBe("go-key")
  })

  test("rejects missing, ambiguous, malformed, and unsafe credentials without echoing values", () => {
    const cases = [
      "not-json",
      JSON.stringify([]),
      JSON.stringify([
        { integrationID: "opencode-go", active: true, value: { type: "key", key: "one" } },
        { integrationID: "opencode-go", active: true, value: { type: "key", key: "two" } },
      ]),
      JSON.stringify([{ integrationID: "opencode-go", active: true, value: { type: "oauth", key: "secret" } }]),
      JSON.stringify([{ integrationID: "opencode-go", active: true, value: { type: "key", key: "secret\nvalue" } }]),
    ]
    for (const input of cases) {
      expect(() => parseOpenCodeGoApiKey(input)).toThrow()
      try {
        parseOpenCodeGoApiKey(input)
      } catch (error) {
        expect(String(error)).not.toContain("secret")
        expect(String(error)).not.toContain("one")
        expect(String(error)).not.toContain("two")
      }
    }
  })
})
