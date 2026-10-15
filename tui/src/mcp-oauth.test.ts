import { expect, test } from "bun:test"
import {
  formatMcpOauthAuthorizeNotice,
  formatMcpOauthCompleteNotice,
  formatMcpOauthRefreshNotice,
} from "./mcp-oauth"

test("formats authorize, complete, and refresh notices without secrets", () => {
  const authorize = formatMcpOauthAuthorizeNotice({
    credential: "docs",
    state: "state-1",
    authorize_url: "https://auth.example/authorize?x=1",
    redirect_uri: "http://127.0.0.1:8765/callback",
    code_challenge_method: "S256",
  }, { copiedAuthorizeUrl: true })
  expect(authorize).toContain("MCP OAUTH AUTHORIZE")
  expect(authorize).toContain("Browser:")
  expect(authorize).toContain("docs")
  expect(authorize).toContain("https://auth.example/authorize?x=1")
  expect(authorize).toContain("Authorize URL copied to the clipboard")
  expect(authorize).toContain("--listen")
  expect(authorize).toContain("/mcp oauth complete docs")
  expect(authorize).toContain("/mcp oauth refresh docs")
  expect(authorize).not.toContain("verifier")
  expect(authorize).not.toContain("refresh_token")

  const complete = formatMcpOauthCompleteNotice({
    name: "docs",
    header_names: ["Authorization"],
  })
  expect(complete).toContain("MCP OAUTH COMPLETE")
  expect(complete).toContain("Authorization")
  expect(complete).toContain("/mcp oauth refresh docs")
  expect(complete).not.toContain("Bearer")

  const refresh = formatMcpOauthRefreshNotice({
    name: "docs",
    header_names: ["Authorization"],
  })
  expect(refresh).toContain("MCP OAUTH REFRESH")
  expect(refresh).toContain("docs")
  expect(refresh).toContain("Authorization")
  expect(refresh).not.toContain("Bearer")
  expect(refresh).not.toContain("refresh_token")
})
