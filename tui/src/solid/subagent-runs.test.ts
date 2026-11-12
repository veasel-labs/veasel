import { describe, expect, test } from "bun:test"
import type { ApiSubagentIntegration, ApiSubagentRun } from "../api-client"
import {
  subagentCanIntegrate,
  subagentIntegrationReviewTarget,
  subagentIntegrationSummary,
  subagentRunDetails,
  toSubagentRunView,
} from "./subagent-runs"

const baseRun: ApiSubagentRun = {
  id: "run-1",
  request_id: "request-1",
  parent_session_id: "parent-1",
  parent_operation_id: "operation-1",
  child_session_id: "child-1",
  agent_id: "explorer",
  target_provider: "",
  target_model: "",
  provider: "provider-a",
  model: "model-a",
  depth: 1,
  status: "completed",
  result: "Inspected the requested files.",
  error: "",
  cancel_requested: false,
  outcome_claimed: true,
  workspace_ready: false,
  workspace_started: false,
  workspace_base_commit: "",
}

describe("subagent usage details", () => {
  test("shows provider-reported usage and optional reported breakdowns", () => {
    const run = toSubagentRunView({
      ...baseRun,
      input_tokens: 1_234,
      output_tokens: 56,
      usage_reported: true,
      cache_read_tokens: 789,
      cache_creation_tokens: 12,
      cache_reported: true,
      reasoning_tokens: 34,
      reasoning_reported: true,
    })

    expect(subagentRunDetails(run)).toContain("Provider-reported usage: 1,234 input · 56 output tokens")
    expect(subagentRunDetails(run)).toContain("Provider-reported cache: 789 read · 12 created tokens")
    expect(subagentRunDetails(run)).toContain("Provider-reported reasoning: 34 tokens")
  })

  test("keeps counters hidden when usage was not reported", () => {
    const run = toSubagentRunView({
      ...baseRun,
      input_tokens: 1_234,
      output_tokens: 56,
      usage_reported: false,
      cache_read_tokens: 789,
      cache_creation_tokens: 12,
      cache_reported: true,
      reasoning_tokens: 34,
      reasoning_reported: true,
    })
    const details = subagentRunDetails(run)

    expect(details).toContain("Provider-reported usage: unavailable")
    expect(details).not.toContain("1,234")
    expect(details).not.toContain("789 read")
    expect(details).not.toContain("34 tokens")
  })

  test("reports missing counters explicitly instead of displaying zero", () => {
    const run = toSubagentRunView({ ...baseRun, usage_reported: true })

    expect(subagentRunDetails(run)).toContain("Provider-reported usage: unavailable input · unavailable output tokens")
  })
})

describe("subagent change integration", () => {
  test("offers integration only for terminal implementer runs", () => {
    expect(subagentCanIntegrate(toSubagentRunView({ ...baseRun, agent_id: "implementer", status: "completed" }))).toBe(true)
    expect(subagentCanIntegrate(toSubagentRunView({ ...baseRun, agent_id: "implementer", status: "uncertain" }))).toBe(true)
    expect(subagentCanIntegrate(toSubagentRunView({ ...baseRun, agent_id: "implementer", status: "running" }))).toBe(false)
    expect(subagentCanIntegrate(toSubagentRunView({ ...baseRun, agent_id: "explorer", status: "completed" }))).toBe(false)
  })

  test("summarizes partial conflicts and routes the first pending proposal for review", () => {
    const response: ApiSubagentIntegration = {
      run_id: "run-1",
      status: "partial",
      proposals: [
        { id: "edit-applied", path: "one.v", status: "applied", diff: "" },
        { id: "edit-pending", path: "two.v", status: "pending", diff: "" },
      ],
      conflicts: [{ path: "three.v", reason: "parent file changed" }],
    }

    expect(subagentIntegrationReviewTarget(response)).toBe("edit-pending")
    expect(subagentIntegrationSummary(response)).toBe("2 proposals · 1 conflict · three.v: parent file changed")
    expect(subagentIntegrationReviewTarget({ ...response, proposals: [] })).toBeUndefined()
  })

  test("bounds conflict detail for narrow TUI feedback", () => {
    const response: ApiSubagentIntegration = {
      run_id: "run-1",
      status: "conflicted",
      proposals: [],
      conflicts: [{ path: "src/long-name.v", reason: "reason ".repeat(40) }],
    }

    expect(subagentIntegrationSummary(response).length).toBeLessThan(190)
  })
})
