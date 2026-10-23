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

describe("VeaselApiClient health", () => {
  const originalFetch = globalThis.fetch

  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  test("getHealth GETs /v1/health", async () => {
    let url = ""
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      url = String(input)
      return new Response(JSON.stringify({ healthy: true, version: "0.42.0-dev" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      })
    }) as typeof fetch
    const client = new VeaselApiClient("http://127.0.0.1:4097")
    const health = await client.getHealth()
    expect(url).toContain("/v1/health")
    expect(health.version).toBe("0.42.0-dev")
  })
})

describe("VeaselApiClient model settings", () => {
  const originalFetch = globalThis.fetch

  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  test("listProviderModels GETs the catalog for a provider", async () => {
    let url = ""
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      url = String(input)
      return new Response(
        JSON.stringify({
          provider: "openai-compatible",
          models: [{ id: "muse-wonder", name: "Muse Wonder" }],
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      )
    }) as typeof fetch
    const client = new VeaselApiClient("http://127.0.0.1:4097")
    const catalog = await client.listProviderModels("openai-compatible")
    expect(url).toContain("/v1/config/models?provider=openai-compatible")
    expect(catalog.models[0]?.id).toBe("muse-wonder")
  })

  test("discoverProviderModels POSTs credentials for catalog discovery", async () => {
    let method = ""
    let body = ""
    globalThis.fetch = (async (_input: RequestInfo | URL, init?: RequestInit) => {
      method = String(init?.method ?? "GET")
      body = String(init?.body ?? "")
      return new Response(
        JSON.stringify({
          provider: "meta",
          models: [{ id: "muse-wonder", name: "Muse Wonder" }],
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      )
    }) as typeof fetch
    const client = new VeaselApiClient("http://127.0.0.1:4097")
    const catalog = await client.discoverProviderModels({
      provider: "meta",
      base_url: "https://api.meta.ai/v1",
      api_key: "test-key",
    })
    expect(method).toBe("POST")
    expect(JSON.parse(body)).toEqual({
      provider: "meta",
      base_url: "https://api.meta.ai/v1",
      api_key: "test-key",
    })
    expect(catalog.models[0]?.id).toBe("muse-wonder")
  })

  test("updateModelSettings POSTs the active model profile", async () => {
    let method = ""
    let body = ""
    globalThis.fetch = (async (_input: RequestInfo | URL, init?: RequestInit) => {
      method = String(init?.method ?? "GET")
      body = String(init?.body ?? "")
      return new Response(
        JSON.stringify({
          active_provider: "openai-compatible",
          profiles: {
            "openai-compatible": {
              model: "muse-wonder",
              base_url: "https://api.example",
              api_key_saved: true,
              max_output_tokens: 8192,
            },
          },
          providers: [],
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      )
    }) as typeof fetch
    const client = new VeaselApiClient("http://127.0.0.1:4097")
    const view = await client.updateModelSettings({
      provider: "openai-compatible",
      model: "muse-wonder",
      base_url: "https://api.example",
      max_output_tokens: 8192,
    })
    expect(method).toBe("POST")
    expect(JSON.parse(body)).toEqual({
      provider: "openai-compatible",
      model: "muse-wonder",
      base_url: "https://api.example",
      max_output_tokens: 8192,
    })
    expect(view.active_provider).toBe("openai-compatible")
    expect(view.profiles["openai-compatible"]?.model).toBe("muse-wonder")
  })
})

describe("VeaselApiClient sendMessage", () => {
  const originalFetch = globalThis.fetch

  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  test("includes execution_policy when not ask", async () => {
    let body = ""
    globalThis.fetch = (async (_input: RequestInfo | URL, init?: RequestInit) => {
      body = String(init?.body ?? "")
      return new Response(JSON.stringify({ operation_id: "op-1", status: "running" }), {
        status: 202,
        headers: { "content-type": "application/json" },
      })
    }) as typeof fetch
    const client = new VeaselApiClient("http://127.0.0.1:4097")
    await client.sendMessage("sess-1", "hi", "op-1", undefined, "auto-edit")
    expect(JSON.parse(body)).toEqual({ content: "hi", execution_policy: "auto-edit" })
    await client.sendMessage("sess-1", "hi", "op-1", undefined, "ask")
    expect(JSON.parse(body)).toEqual({ content: "hi" })
  })
})

describe("VeaselApiClient renameSession", () => {
  const originalFetch = globalThis.fetch

  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  test("PATCHes session title", async () => {
    let method = ""
    let body = ""
    let url = ""
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      url = String(input)
      method = String(init?.method ?? "GET")
      body = String(init?.body ?? "")
      return new Response(
        JSON.stringify({
          id: "sess-1",
          title: "Renamed",
          directory: "/tmp",
          created_at: "2026-10-16T00:00:00Z",
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      )
    }) as typeof fetch
    const client = new VeaselApiClient("http://127.0.0.1:4097")
    const session = await client.renameSession("sess-1", "Renamed")
    expect(method).toBe("PATCH")
    expect(url).toContain("/v1/sessions/sess-1")
    expect(JSON.parse(body)).toEqual({ title: "Renamed" })
    expect(session.title).toBe("Renamed")
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

  test("decideWorkspaceEdit POSTs approve/reject", async () => {
    let method = ""
    let url = ""
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      url = String(input)
      method = String(init?.method ?? "GET")
      return new Response(JSON.stringify({ id: "edit-1", status: "applied" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      })
    }) as typeof fetch
    const client = new VeaselApiClient("http://127.0.0.1:4097")
    const result = await client.decideWorkspaceEdit("sess-1", "edit-1", "approve")
    expect(method).toBe("POST")
    expect(url).toContain("/workspace/edits/edit-1/approve")
    expect(result.status).toBe("applied")
  })

  test("listWorkspaceCommands and decideWorkspaceCommand hit command routes", async () => {
    const calls: Array<{ url: string; method: string }> = []
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      calls.push({ url, method: String(init?.method ?? "GET") })
      if (url.includes("/approve") || url.includes("/reject")) {
        return new Response(JSON.stringify({ id: "cmd-1", status: "rejected" }), {
          status: 200,
          headers: { "content-type": "application/json" },
        })
      }
      if (url.includes("/workspace/commands/")) {
        return new Response(
          JSON.stringify({
            id: "cmd-1",
            command: "echo hi",
            cwd: "/tmp",
            timeout_seconds: 30,
            status: "pending",
          }),
          { status: 200, headers: { "content-type": "application/json" } },
        )
      }
      return new Response(
        JSON.stringify([
          {
            id: "cmd-1",
            command: "echo hi",
            cwd: "/tmp",
            timeout_seconds: 30,
            status: "pending",
          },
        ]),
        { status: 200, headers: { "content-type": "application/json" } },
      )
    }) as typeof fetch
    const client = new VeaselApiClient("http://127.0.0.1:4097")
    const listed = await client.listWorkspaceCommands("sess-1")
    expect(listed[0]?.command).toBe("echo hi")
    await client.getWorkspaceCommand("sess-1", "cmd-1")
    await client.decideWorkspaceCommand("sess-1", "cmd-1", "reject")
    expect(calls.map((call) => call.method)).toEqual(["GET", "GET", "POST"])
    expect(calls[2]?.url).toContain("/workspace/commands/cmd-1/reject")
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

  test("getUsage hits the global usage route", async () => {
    const calls: string[] = []
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      calls.push(String(input))
      return new Response(
        JSON.stringify({
          sessions: 2,
          completed_turns: 3,
          reported_turns: 2,
          input_tokens: 150,
          output_tokens: 30,
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
    }) as typeof fetch

    const client = new VeaselApiClient("http://127.0.0.1:4097")
    const usage = await client.getUsage()
    expect(calls[0]).toContain("/v1/usage")
    expect(usage.sessions).toBe(2)
    expect(usage.input_tokens).toBe(150)
  })

  test("listGlobalOperations sends a bounded cursor page request", async () => {
    let requestedUrl = ""
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      requestedUrl = String(input)
      return new Response(JSON.stringify({
        operations: [{
          session_title: "Example",
          operation: { id: "op-id", session_id: "session-id", status: "completed" },
        }],
        next_before: "op-id",
      }), { status: 200, headers: { "content-type": "application/json" } })
    }) as typeof fetch
    const client = new VeaselApiClient("http://127.0.0.1:4097")
    const page = await client.listGlobalOperations({ before: "cursor-id", limit: 50, search: "  parser error  " })
    expect(requestedUrl).toBe("http://127.0.0.1:4097/v1/operations?before=cursor-id&limit=50&search=parser+error")
    expect(page.operations[0]?.session_title).toBe("Example")
    expect(page.next_before).toBe("op-id")
  })

  test("forkSession posts to the fork route", async () => {
    const calls: Array<{ url: string; method?: string }> = []
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      calls.push({ url: String(input), method: init?.method })
      return new Response(
        JSON.stringify({
          id: "sess-2",
          title: "Chat (fork)",
          directory: "/tmp/work",
          created_at: "2026-10-19T00:00:00Z",
        }),
        { status: 201, headers: { "content-type": "application/json" } },
      )
    }) as typeof fetch

    const client = new VeaselApiClient("http://127.0.0.1:4097")
    const forked = await client.forkSession("sess-1")
    expect(calls[0]?.url).toContain("/v1/sessions/sess-1/fork")
    expect(calls[0]?.method).toBe("POST")
    expect(forked.id).toBe("sess-2")
    expect(forked.title).toBe("Chat (fork)")
  })

  test("deleteSession issues DELETE to the session route", async () => {
    const calls: Array<{ url: string; method?: string }> = []
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      calls.push({ url: String(input), method: init?.method })
      return new Response(JSON.stringify({ deleted: "sess-1" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      })
    }) as typeof fetch

    const client = new VeaselApiClient("http://127.0.0.1:4097")
    const result = await client.deleteSession("sess-1")
    expect(calls[0]?.url).toContain("/v1/sessions/sess-1")
    expect(calls[0]?.method).toBe("DELETE")
    expect(result.deleted).toBe("sess-1")
  })

  test("listConfiguredMcpServers passes directory query", async () => {
    let url = ""
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      url = String(input)
      return new Response(JSON.stringify({ servers: [] }), {
        status: 200,
        headers: { "content-type": "application/json" },
      })
    }) as typeof fetch
    const client = new VeaselApiClient("http://127.0.0.1:4097")
    await client.listConfiguredMcpServers("/tmp/proj")
    expect(url).toContain("/v1/mcp-servers?")
    expect(url).toContain("directory=%2Ftmp%2Fproj")
  })

  test("configured MCP mutations use the scoped server API", async () => {
    const calls: Array<{ url: string; method: string; body?: string }> = []
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      calls.push({ url: String(input), method: init?.method ?? "GET", body: typeof init?.body === "string" ? init.body : undefined })
      return new Response(JSON.stringify({ name: "docs", transport: "stdio", scope: "project", enabled: false }), {
        status: 200,
        headers: { "content-type": "application/json" },
      })
    }) as typeof fetch
    const client = new VeaselApiClient("http://127.0.0.1:4097")
    await client.addConfiguredMcpServer({ name: "docs", transport: "stdio", command: "node", args: ["server.js"], scope: "project", directory: "/tmp/proj" })
    await client.updateConfiguredMcpServer("docs", { enabled: false, scope: "project", directory: "/tmp/proj" })
    await client.removeConfiguredMcpServer("docs", "project", "/tmp/proj")
    expect(calls.map(({ method }) => method)).toEqual(["POST", "PATCH", "DELETE"])
    expect(calls[0]?.url).toBe("http://127.0.0.1:4097/v1/mcp-servers")
    expect(JSON.parse(calls[0]?.body ?? "{}")).toMatchObject({ scope: "project", directory: "/tmp/proj", enabled: true })
    expect(calls[1]?.url).toContain("scope=project&directory=%2Ftmp%2Fproj")
    expect(calls[2]?.url).toContain("/v1/mcp-servers/docs?scope=project&directory=%2Ftmp%2Fproj")
  })
})
