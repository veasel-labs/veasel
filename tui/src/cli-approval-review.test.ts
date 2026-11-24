import { describe, expect, test } from "bun:test"
import {
  cliApprovalCanApprove,
  cliApprovalInputPreview,
  createCliApprovalPoller,
  type CliToolApproval,
} from "./cli-approval-review"

describe("installed CLI approval review", () => {
  test("escapes terminal controls in provider-supplied arguments", () => {
    expect(cliApprovalInputPreview("line\u001b[2J\nnext")).toEqual({
      text: "line\\u001b[2J\\u000anext",
      fullyVisible: true,
    })
  })

  test("does not permit approval when the complete request is not displayed", () => {
    const preview = cliApprovalInputPreview("x".repeat(20), 10)
    expect(preview.fullyVisible).toBe(false)
    expect(preview.truncationNotice).toContain("Input truncated")
    expect(cliApprovalCanApprove("approval-1", new Set())).toBe(false)
    expect(cliApprovalCanApprove("approval-1", new Set(["approval-1"]))).toBe(true)
  })

  test("notifies once per pending request and ignores stale sessions", async () => {
    const approval: CliToolApproval = {
      id: "approval-1",
      session_id: "session-1",
      request_id: "request-1",
      tool_name: "Edit",
      input_json: "{}",
      status: "pending",
      created_at: "",
      updated_at: "",
    }
    const notices: string[] = []
    let currentSession = "session-1"
    const poller = createCliApprovalPoller({
      list: async () => [approval],
      isCurrent: (sessionId) => sessionId === currentSession,
      onPending: (sessionId) => { notices.push(sessionId) },
    })
    poller.start("session-1")
    await poller.pollNow()
    await poller.pollNow()
    expect(notices).toEqual(["session-1"])

    currentSession = "session-2"
    poller.start("session-1")
    await poller.pollNow()
    expect(notices).toEqual(["session-1"])
    poller.stop()
  })

  test("retries notification when the review inventory is temporarily unavailable", async () => {
    const approval: CliToolApproval = {
      id: "approval-1",
      session_id: "session-1",
      request_id: "request-1",
      tool_name: "Edit",
      input_json: "{}",
      status: "pending",
      created_at: "",
      updated_at: "",
    }
    let attempts = 0
    const poller = createCliApprovalPoller({
      list: async () => [approval],
      isCurrent: () => true,
      onPending: async () => {
        attempts++
        return attempts > 1
      },
    })
    poller.start("session-1")
    await poller.pollNow()
    await poller.pollNow()
    await poller.pollNow()
    expect(attempts).toBe(2)
    poller.stop()
  })
})
