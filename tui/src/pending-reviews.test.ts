import { describe, expect, test } from "bun:test"
import {
  createPendingReviewInventoryCoordinator,
  formatPendingReviewStatus,
  loadPendingReviewInventory,
  pendingReviewDecisionFailureNotice,
  pendingReviewInventoryFailureNotice,
  pendingReviewActions,
  pendingReviewOpenCommand,
  statusWithPendingReviewFailure,
  statusWithPendingReviews,
  totalPendingReviews,
} from "./pending-reviews"

describe("formatPendingReviewStatus", () => {
  test("returns nothing when the session has no pending reviews", () => {
    expect(formatPendingReviewStatus({ edits: 0, commands: 0, mcp: 0 })).toBeUndefined()
    expect(totalPendingReviews({ edits: 0, commands: 0, mcp: 0 })).toBe(0)
    expect(pendingReviewActions({ edits: 0, commands: 0, mcp: 0 })).toEqual([])
    expect(pendingReviewOpenCommand({ edits: 0, commands: 0, mcp: 0 })).toBeUndefined()
  })

  test("lists each pending review family with the slash that opens it", () => {
    expect(formatPendingReviewStatus({ edits: 1, commands: 0, mcp: 0 })).toBe(
      "▲ attention  ·  review needed  ·  1 pending  ·  1 edit  ·  /patches  ·  Ctrl+R",
    )
    expect(formatPendingReviewStatus({ edits: 1, commands: 0, mcp: 0 }, "openai/gpt-5")).toBe(
      "▲ attention  ·  openai/gpt-5  ·  1 pending  ·  1 edit  ·  /patches  ·  Ctrl+R",
    )
    expect(formatPendingReviewStatus({ edits: 2, commands: 1, mcp: 3 })).toBe(
      "▲ attention  ·  review needed  ·  6 pending  ·  2 edits · 1 shell · 3 MCP  ·  /patches · /commands · /mcp calls  ·  Ctrl+R",
    )
    expect(pendingReviewActions({ edits: 2, commands: 1, mcp: 3 })).toEqual([
      "/patches",
      "/commands",
      "/mcp calls",
    ])
    expect(pendingReviewOpenCommand({ edits: 0, commands: 2, mcp: 1 })).toBe("/commands")
  })

  test("prefers the review cue over a completed-turn status", () => {
    expect(statusWithPendingReviews("● openai-compatible  ·  fixture  ·  1.2k in · 340 out", {
      edits: 1,
      commands: 0,
      mcp: 0,
    })).toBe("▲ attention  ·  review needed  ·  1 pending  ·  1 edit  ·  /patches  ·  Ctrl+R")
    expect(statusWithPendingReviews("● openai-compatible  ·  fixture", {
      edits: 0,
      commands: 0,
      mcp: 0,
    })).toBe("● openai-compatible  ·  fixture")
  })
})

describe("pending review inventory", () => {
  test("distinguishes a successfully empty inventory from an unavailable one", async () => {
    const fetcher = async () => Response.json([])
    const empty = await loadPendingReviewInventory(
      "http://127.0.0.1:8000",
      "session/one",
      undefined,
      fetcher,
    )
    expect(empty).toEqual({
      ok: true,
      counts: { edits: 0, commands: 0, mcp: 0 },
      queue: [],
    })
    expect(statusWithPendingReviews("● connected", { edits: 0, commands: 0, mcp: 0 })).toBe("● connected")

    const unavailable = await loadPendingReviewInventory(
      "http://127.0.0.1:8000",
      "session/one",
      undefined,
      async () => new Response("unavailable", { status: 503 }),
    )
    expect(unavailable).toEqual({ ok: false })
    expect(statusWithPendingReviewFailure({ edits: 0, commands: 0, mcp: 0 })).toContain("approvals unavailable")
    expect(pendingReviewInventoryFailureNotice()).toContain("Ctrl+R to retry")
    expect(pendingReviewInventoryFailureNotice()).toContain("/commands")
  })

  test("loads all three queues atomically and preserves their pending IDs", async () => {
    const requests: string[] = []
    const fetcher = async (input: string | URL | Request) => {
      const url = String(input)
      requests.push(url)
      if (url.endsWith("/workspace/edits")) {
        return Response.json([{ id: "edit-1", status: "pending" }, { id: "edit-2", status: "applied" }])
      }
      if (url.endsWith("/workspace/commands")) {
        return Response.json([{ id: "command-1", status: "pending" }])
      }
      return Response.json([{ id: "mcp-1", status: "pending" }])
    }
    const result = await loadPendingReviewInventory("http://127.0.0.1:8000/", "session/one", undefined, fetcher)
    expect(requests).toEqual([
      "http://127.0.0.1:8000/v1/sessions/session%2Fone/workspace/edits",
      "http://127.0.0.1:8000/v1/sessions/session%2Fone/workspace/commands",
      "http://127.0.0.1:8000/v1/sessions/session%2Fone/mcp-tool-calls",
    ])
    expect(result).toEqual({
      ok: true,
      counts: { edits: 1, commands: 1, mcp: 1 },
      queue: [
        { kind: "patch", id: "edit-1", pending: true },
        { kind: "command", id: "command-1", pending: true },
        { kind: "mcp", id: "mcp-1", pending: true },
      ],
    })
  })

  test("a partial non-OK response makes the entire inventory unavailable", async () => {
    const fetcher = async (input: string | URL | Request) =>
      String(input).endsWith("/workspace/commands")
        ? new Response("temporarily unavailable", { status: 503 })
        : Response.json([])
    expect(await loadPendingReviewInventory("http://127.0.0.1:8000", "session-1", undefined, fetcher))
      .toEqual({ ok: false })
  })

  test("a late inventory response cannot replace the newest same-session refresh", async () => {
    const coordinator = createPendingReviewInventoryCoordinator()
    let releaseOldRequest!: () => void
    const oldRequestGate = new Promise<void>((resolve) => { releaseOldRequest = resolve })
    const oldRequest = coordinator.load(
      "http://127.0.0.1:8000",
      "session-1",
      undefined,
      async () => {
        await oldRequestGate
        return Response.json([])
      },
    )
    const newestRequest = await coordinator.load(
      "http://127.0.0.1:8000",
      "session-1",
      undefined,
      async (input) => String(input).endsWith("/workspace/commands")
        ? Response.json([{ id: "command-new", status: "pending" }])
        : Response.json([]),
    )
    expect(newestRequest.current).toBe(true)
    expect(newestRequest.inventory).toMatchObject({
      ok: true,
      counts: { edits: 0, commands: 1, mcp: 0 },
      queue: [{ kind: "command", id: "command-new", pending: true }],
    })

    releaseOldRequest()
    const staleRequest = await oldRequest
    expect(staleRequest.current).toBe(false)
    expect(staleRequest.inventory).toEqual({
      ok: true,
      counts: { edits: 0, commands: 0, mcp: 0 },
      queue: [],
    })
  })

  test("approval decisions are blocked while inventory is unavailable", () => {
    expect(pendingReviewDecisionFailureNotice(false)).toBeUndefined()
    expect(pendingReviewDecisionFailureNotice(true)).toContain("Approval and rejection are paused")
    expect(pendingReviewDecisionFailureNotice(false, true)).toContain("while the review queue refreshes")
  })
})
