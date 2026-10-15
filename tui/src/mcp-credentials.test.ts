import { expect, test, describe } from "bun:test"
import {
  formatMcpCredentialCatalog,
  formatMcpCredentialLine,
  parseMcpCredentialHeaders,
} from "./mcp-credentials"

describe("mcp credentials formatting", () => {
  test("lists header names without inventing values", () => {
    expect(formatMcpCredentialLine({ name: "docs", header_names: ["Authorization", "X-Api-Key"] })).toBe(
      "• docs  ·  headers: Authorization, X-Api-Key",
    )
    const empty = formatMcpCredentialCatalog({ credentials: [] })
    expect(empty).toContain("MCP HTTP CREDENTIALS")
    expect(empty).toContain("No named credentials yet")
    expect(empty).toContain("/mcp credential set")
    const filled = formatMcpCredentialCatalog({
      path: "/tmp/mcp-credentials.json",
      credentials: [{ name: "docs", header_names: ["Authorization"] }],
    })
    expect(filled).toContain("Store: /tmp/mcp-credentials.json")
    expect(filled).toContain("• docs  ·  headers: Authorization")
    expect(filled).toContain("/mcp credential remove")
    expect(filled).not.toContain("Bearer")
  })

  test("parses Header=value pairs for set", () => {
    expect(parseMcpCredentialHeaders("Authorization=Bearer_tok X-Api-Key=abc").headers).toEqual({
      Authorization: "Bearer_tok",
      "X-Api-Key": "abc",
    })
    expect(parseMcpCredentialHeaders("").error).toContain("at least one")
    expect(parseMcpCredentialHeaders("Authorization").error).toContain("Header=value")
    expect(parseMcpCredentialHeaders("A=1 A=2").error).toContain("Duplicate")
  })
})
