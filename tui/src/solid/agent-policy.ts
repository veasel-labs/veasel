import type { SolidAgent } from "./component/agent-dialog"

/**
 * LiveApp "agents" map to Veasel per-turn `execution_policy` values
 * (`ask` | `auto-edit` | `sandbox-auto`). OpenCode build/plan/review labels
 * stay on the fixture shell demos.
 */
export const EXECUTION_POLICY_AGENTS: SolidAgent[] = [
  {
    id: "ask",
    description: "Ask before file edits, shell, and MCP (default)",
  },
  {
    id: "auto-edit",
    description: "Auto-apply file edits; still ask for shell and MCP",
  },
  {
    id: "sandbox-auto",
    description: "Auto edits + sandboxed shell when the OS sandbox wraps",
  },
]

export type ExecutionPolicyId = "ask" | "auto-edit" | "sandbox-auto"

export function isExecutionPolicyId(value: string): value is ExecutionPolicyId {
  return value === "ask" || value === "auto-edit" || value === "sandbox-auto"
}

/** Body field for POST /v1/sessions/:id/messages (`execution_policy`). */
export function executionPolicyForAgent(agentId: string): ExecutionPolicyId {
  return isExecutionPolicyId(agentId) ? agentId : "ask"
}

export function agentPolicyLabel(agentId: string): string {
  const agent = EXECUTION_POLICY_AGENTS.find((item) => item.id === agentId)
  return agent ? `${agent.id} · ${agent.description}` : agentId
}
