import { expect, test } from "bun:test"
import { VeaselApiClient } from "../api-client"
import { decideSolidReviews, inspectSolidReview, loadPendingSolidReviews } from "./reviews-inventory"
import { subagentIntegrationReviewTarget } from "./subagent-runs"

test("integrateSubagent posts to the scoped run endpoint with an empty body", async () => {
  let observed: { method: string; path: string; body: string } | undefined
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      observed = {
        method: request.method,
        path: new URL(request.url).pathname,
        body: await request.text(),
      }
      return Response.json({
        run_id: "run/id",
        status: "partial",
        proposals: [{ id: "edit-1", path: "src/main.v", status: "pending", diff: "+safe" }],
        conflicts: [{ path: "src/other.v", reason: "changed in parent" }],
      })
    },
  })
  try {
    const result = await new VeaselApiClient(server.url.origin).integrateSubagent("session/id", "run/id")
    expect(observed).toEqual({
      method: "POST",
      path: "/v1/sessions/session%2Fid/subagents/run%2Fid/integrate",
      body: "",
    })
    expect(result.proposals[0]?.status).toBe("pending")
    expect(result.conflicts[0]?.path).toBe("src/other.v")
  } finally {
    server.stop(true)
  }
})

test("integrated proposals enter the existing review flow and wait for explicit approval", async () => {
  const requests: string[] = []
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const path = new URL(request.url).pathname
      requests.push(`${request.method} ${path}`)
      if (path.endsWith("/integrate")) {
        return Response.json({ run_id: "run-1", status: "integrated", proposals: [
          { id: "edit-1", path: "src/main.v", status: "pending", diff: "+safe" },
        ], conflicts: [] })
      }
      if (path.endsWith("/workspace/edits")) {
        return Response.json([{ id: "edit-1", path: "src/main.v", status: "pending" }])
      }
      if (path.endsWith("/workspace/commands") || path.endsWith("/mcp-tool-calls")) return Response.json([])
      if (path.endsWith("/workspace/edits/edit-1/approve")) return Response.json({ id: "edit-1", status: "applied" })
      if (path.endsWith("/workspace/edits/edit-1")) {
        return Response.json({ id: "edit-1", path: "src/main.v", status: "pending", diff: "+safe" })
      }
      return new Response("not found", { status: 404 })
    },
  })
  try {
    const api = new VeaselApiClient(server.url.origin)
    const result = await api.integrateSubagent("parent", "run-1")
    const editId = subagentIntegrationReviewTarget(result)!
    const reviews = await loadPendingSolidReviews(api, "parent")
    expect(reviews.map((review) => review.id)).toEqual([editId])
    expect(requests.some((request) => request.endsWith("/approve"))).toBe(false)

    const target = { kind: "patch" as const, id: editId, pending: true }
    const inspected = await inspectSolidReview(api, "parent", target)
    expect(inspected).toMatchObject({ kind: "patch", diff: "+safe" })
    expect(requests.some((request) => request.endsWith("/approve"))).toBe(false)

    const decision = await decideSolidReviews(api, "parent", "approve", [target])
    expect(decision.settled).toEqual([target])
    expect(requests.filter((request) => request.endsWith("/approve"))).toHaveLength(1)
  } finally {
    server.stop(true)
  }
})
