import { describe, expect, test } from "bun:test"
import {
  solidCommandFromSummary,
  solidCliFromApproval,
  solidMcpFromApproval,
  solidPatchFromEdit,
} from "./reviews-inventory"

describe("reviews-inventory mappers", () => {
  test("maps workspace edit proposals to patch reviews", () => {
    expect(
      solidPatchFromEdit({
        id: "edit-1",
        path: "src/a.ts",
        status: "pending",
        diff: "@@ -1 +1 @@\n-a\n+b\n",
      }),
    ).toEqual({
      kind: "patch",
      id: "edit-1",
      pending: true,
      path: "src/a.ts",
      diff: "@@ -1 +1 @@\n-a\n+b\n",
      status: "pending",
    })
  })

  test("maps shell commands and MCP approvals", () => {
    expect(
      solidCommandFromSummary({
        id: "cmd-1",
        command: "ls",
        cwd: "/tmp",
        timeout_seconds: 30,
        status: "pending",
      }),
    ).toMatchObject({
      kind: "command",
      id: "cmd-1",
      pending: true,
      command: "ls",
      cwd: "/tmp",
      timeoutSeconds: 30,
    })
    expect(
      solidMcpFromApproval({
        id: "mcp-1",
        operation_id: "op-1",
        plugin_name: "demo",
        server_name: "fs",
        tool_name: "read",
        status: "pending",
        arguments_json: '{"path":"x"}',
      }),
    ).toEqual({
      kind: "mcp",
      id: "mcp-1",
      pending: true,
      plugin: "demo",
      server: "fs",
      tool: "read",
      operationId: "op-1",
      argumentsText: '{"path":"x"}',
      stdioSandbox: undefined,
    })
  })

  test("escapes and bounds installed CLI approval arguments", () => {
    expect(solidCliFromApproval({
      id: "cli-1",
      session_id: "session-1",
      request_id: "request-1",
      tool_name: "Edit",
      input_json: '{"path":"src/a.ts","text":"safe"}',
      status: "pending",
      created_at: "",
      updated_at: "",
    })).toEqual({
      kind: "cli",
      id: "cli-1",
      pending: true,
      toolName: "Edit",
      requestId: "request-1",
      argumentsText: '{"path":"src/a.ts","text":"safe"}',
      inputFullyVisible: true,
    })
    const truncated = solidCliFromApproval({
      id: "cli-2",
      session_id: "session-1",
      request_id: "request-2",
      tool_name: "Edit",
      input_json: '{"text":"' + "x".repeat(13_000) + '"}',
      status: "pending",
      created_at: "",
      updated_at: "",
    })
    expect(truncated).toMatchObject({ kind: "cli", inputFullyVisible: false })
  })
})
