import { describe, expect, test } from "bun:test"
import { solidMcpServersFromCatalog } from "./mcp-inventory"

describe("mcp inventory", () => {
  test("marks trusted configured servers connected", () => {
    const rows = solidMcpServersFromCatalog(
      {
        servers: [
          { name: "echo", enabled: true, transport: "stdio", scope: "user" },
          { name: "off", enabled: false, transport: "stdio", scope: "project" },
        ],
      },
      [{ plugin_name: "configured", server_name: "echo" }],
    )
    expect(rows.map((row) => row.name)).toEqual(["configured/echo", "configured/off"])
    expect(rows[0]?.status).toBe("connected")
    expect(rows[1]?.status).toBe("disabled")
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
        status: "connected",
      },
    ])
  })
})
