import { describe, expect, test } from "bun:test"
import { solidMcpServersFromCatalog } from "./mcp-inventory"

describe("mcp inventory", () => {
  test("distinguishes trusted, available, and disabled configured servers", () => {
    const rows = solidMcpServersFromCatalog(
      {
        servers: [
          { name: "echo", enabled: true, transport: "stdio", scope: "user" },
          { name: "off", enabled: false, transport: "stdio", scope: "project" },
          { name: "http", enabled: true, transport: "http", scope: "project" },
        ],
      },
      [{ plugin_name: "configured", server_name: "echo" }],
    )
    expect(rows.map((row) => row.name)).toEqual(["configured/echo", "configured/http", "configured/off"])
    expect(rows[0]?.status).toBe("trusted")
    expect(rows[1]?.status).toBe("available")
    expect(rows[2]?.status).toBe("disabled")
  })

  test("includes session-trusted plugin servers not in catalog", () => {
    const rows = solidMcpServersFromCatalog(
      { servers: [] },
      [{ plugin_name: "local-tools", server_name: "workspace" }],
    )
    expect(rows).toEqual([
      {
        name: "local-tools/workspace",
        transport: "plugin",
        scope: "session",
        status: "trusted",
      },
    ])
  })
})
