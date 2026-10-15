import { expect, test } from "bun:test"
import { formatMcpOauthAuthorizeNotice, formatMcpOauthCompleteNotice } from "./mcp-oauth"

test("formats authorize and complete notices without secrets", () => {
  const authorize = formatMcpOauthAuthorizeNotice({
    credential: "docs",
    state: "state-1",
    authorize_url: "https://auth.example/authorize?x=1",
    redirect_uri: "http://127.0.0.1:8765/callback",
    code_challenge_method: "S256",
  })
  expect(authorize).toContain("MCP OAUTH AUTHORIZE")
  expect(authorize).toContain("docs")
  expect(authorize).toContain("https://auth.example/authorize?x=1")
  expect(authorize).toContain("/mcp oauth complete docs")
  expect(authorize).not.toContain("verifier")

  const complete = formatMcpOauthCompleteNotice({
    name: "docs",
    header_names: ["Authorization"],
  })
  expect(complete).toContain("MCP OAUTH COMPLETE")
  expect(complete).toContain("Authorization")
  expect(complete).not.toContain("Bearer")
})
