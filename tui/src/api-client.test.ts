import { afterEach, describe, expect, test } from "bun:test"
import { resolveLoopbackApiBase, VeaselApiClient } from "./api-client"

describe("resolveLoopbackApiBase", () => {
  test("defaults to loopback port 4097", () => {
    expect(resolveLoopbackApiBase({})).toBe("http://127.0.0.1:4097")
  })

  test("honors VEASEL_PORT and VEASEL_API_URL on loopback", () => {
    expect(resolveLoopbackApiBase({ VEASEL_PORT: "5100" })).toBe("http://127.0.0.1:5100")
    expect(resolveLoopbackApiBase({ VEASEL_API_URL: "http://localhost:4200/" })).toBe(
      "http://localhost:4200",
    )
  })

  test("rejects non-loopback and credentialed URLs", () => {
    expect(() => resolveLoopbackApiBase({ VEASEL_API_URL: "http://example.com" })).toThrow(
      /loopback/,
    )
    expect(() =>
      resolveLoopbackApiBase({ VEASEL_API_URL: "http://user:pass@127.0.0.1:4097" }),
    ).toThrow(/loopback/)
    expect(() => resolveLoopbackApiBase({ VEASEL_API_URL: "https://127.0.0.1:4097" })).toThrow(
      /loopback/,
    )
  })
})

describe("VeaselApiClient git worktrees", () => {
  const originalFetch = globalThis.fetch

  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  test("listGitWorktrees GETs the session catalog", async () => {
    const calls: string[] = []
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      calls.push(String(input))
      return new Response(
        JSON.stringify({
          worktrees: [
            {
              path: "/tmp/repo",
              branch: "main",
              locked: false,
              missing: false,
              is_main: true,
            },
          ],
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      )
    }) as typeof fetch

    const client = new VeaselApiClient("http://127.0.0.1:4097")
    const catalog = await client.listGitWorktrees("sess-1")
    expect(calls[0]).toContain("/v1/sessions/sess-1/workspace/git/worktrees")
    expect(catalog.worktrees).toHaveLength(1)
    expect(catalog.worktrees[0]?.is_main).toBe(true)
  })

  test("addGitWorktree POSTs path and new_branch", async () => {
    let body = ""
    globalThis.fetch = (async (_input: RequestInfo | URL, init?: RequestInit) => {
      body = String(init?.body ?? "")
      return new Response(
        JSON.stringify({
          path: "/tmp/feature",
          branch: "feature",
          locked: false,
          missing: false,
          is_main: false,
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      )
    }) as typeof fetch

    const client = new VeaselApiClient("http://127.0.0.1:4097")
    const tree = await client.addGitWorktree("sess-1", {
      path: "/tmp/feature",
      new_branch: "feature",
    })
    expect(JSON.parse(body)).toEqual({ path: "/tmp/feature", new_branch: "feature" })
    expect(tree.path).toBe("/tmp/feature")
  })
})

describe("VeaselApiClient workspace edits", () => {
  const originalFetch = globalThis.fetch

  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  test("listWorkspaceEdits and getWorkspaceEdit hit session edit routes", async () => {
    const calls: string[] = []
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = String(input)
      calls.push(url)
      if (url.includes("/workspace/edits/") && !url.endsWith("/workspace/edits")) {
        return new Response(
          JSON.stringify({
            id: "edit-1",
            path: "src/main.v",
            status: "pending",
            diff: "--- a\n+++ b\n+hi\n",
          }),
          { status: 200, headers: { "content-type": "application/json" } },
        )
      }
      return new Response(
        JSON.stringify([{ id: "edit-1", path: "src/main.v", status: "pending" }]),
        { status: 200, headers: { "content-type": "application/json" } },
      )
    }) as typeof fetch

    const client = new VeaselApiClient("http://127.0.0.1:4097")
    const listed = await client.listWorkspaceEdits("sess-1")
    expect(calls[0]).toContain("/v1/sessions/sess-1/workspace/edits")
    expect(listed[0]?.path).toBe("src/main.v")
    const proposal = await client.getWorkspaceEdit("sess-1", "edit-1")
    expect(calls[1]).toContain("/workspace/edits/edit-1")
    expect(proposal.diff).toContain("+hi")
  })
})

describe("VeaselApiClient usage and MCP", () => {
  const originalFetch = globalThis.fetch

  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  test("getSessionUsage and listSessionMcpServers hit session routes", async () => {
    const calls: string[] = []
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = String(input)
      calls.push(url)
      if (url.includes("/usage")) {
        return new Response(
          JSON.stringify({
            session_id: "sess-1",
            completed_turns: 2,
            reported_turns: 1,
            input_tokens: 10,
            output_tokens: 4,
            usage_reported: true,
            cache_read_tokens: 0,
            cache_creation_tokens: 0,
            cache_reported: false,
            reasoning_tokens: 0,
            reasoning_reported: false,
            cost: "unavailable",
          }),
          { status: 200, headers: { "content-type": "application/json" } },
        )
      }
      return new Response(
        JSON.stringify([{ plugin_name: "local-tools", server_name: "workspace" }]),
        { status: 200, headers: { "content-type": "application/json" } },
      )
    }) as typeof fetch

    const client = new VeaselApiClient("http://127.0.0.1:4097")
    const usage = await client.getSessionUsage("sess-1")
    expect(calls[0]).toContain("/v1/sessions/sess-1/usage")
    expect(usage.input_tokens).toBe(10)
    const servers = await client.listSessionMcpServers("sess-1")
    expect(calls[1]).toContain("/v1/sessions/sess-1/mcp-servers")
    expect(servers[0]?.server_name).toBe("workspace")
  })
})
