import { describe, expect, test } from "bun:test"
import {
  EXECUTION_POLICY_AGENTS,
  agentPolicyLabel,
  executionPolicyForAgent,
  isExecutionPolicyId,
} from "./agent-policy"

describe("agent-policy", () => {
  test("exposes ask / auto-edit / sandbox-auto agents", () => {
    expect(EXECUTION_POLICY_AGENTS.map((agent) => agent.id)).toEqual([
      "ask",
      "auto-edit",
      "sandbox-auto",
    ])
  })

  test("maps agent ids to execution_policy body values", () => {
    expect(executionPolicyForAgent("ask")).toBe("ask")
    expect(executionPolicyForAgent("auto-edit")).toBe("auto-edit")
    expect(executionPolicyForAgent("sandbox-auto")).toBe("sandbox-auto")
    expect(executionPolicyForAgent("unknown")).toBe("ask")
    expect(isExecutionPolicyId("auto-edit")).toBe(true)
    expect(isExecutionPolicyId("build")).toBe(false)
  })

  test("formats picker labels", () => {
    expect(agentPolicyLabel("ask")).toContain("Ask before")
  })
})
