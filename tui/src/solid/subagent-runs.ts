import type { DialogSelectOption } from "./ui/dialog-select"
import type { ApiSubagentRun } from "../api-client"

/** Durable child state returned by the orchestration API. Progress is absent
 * by design: the backend currently exposes lifecycle states, not percentages. */

export type SubagentRunView = {
  id: string
  child_session_id: string
  parent_operation_id: string
  agent_id: string
  task: string
  status: "queued" | "running" | "completed" | "failed" | "cancelled" | "uncertain"
  provider: string
  model: string
  cancel_requested: boolean
  result?: string
  error?: string
  outcome_claimed: boolean
  workspace_ready: boolean
  workspace_started: boolean
  workspace_base_commit: string
}

export function toSubagentRunView(run: ApiSubagentRun): SubagentRunView {
  return {
    id: run.id,
    child_session_id: run.child_session_id,
    parent_operation_id: run.parent_operation_id,
    agent_id: run.agent_id,
    task: run.task ?? run.requested_title ?? "Delegated task",
    status: run.status,
    provider: run.provider,
    model: run.model,
    cancel_requested: run.cancel_requested,
    result: run.result || undefined,
    error: run.error || undefined,
    outcome_claimed: run.outcome_claimed,
    workspace_ready: run.workspace_ready,
    workspace_started: run.workspace_started,
    workspace_base_commit: run.workspace_base_commit,
  }
}

export function subagentRunTitle(run: SubagentRunView): string {
  return `${run.status.toUpperCase()} · ${run.agent_id}`
}

export function subagentRunDescription(run: SubagentRunView): string {
  const task = run.task.replace(/\s+/g, " ").trim()
  const shortTask = task.length > 96 ? `${task.slice(0, 93)}…` : task
  return `${shortTask} · ${run.provider}/${run.model}`
}

export function subagentRunOption(run: SubagentRunView): DialogSelectOption<string> {
  return {
    title: subagentRunTitle(run),
    value: run.id,
    description: subagentRunDescription(run),
    footer: run.cancel_requested ? "cancellation requested" : undefined,
    searchText: [run.id, run.child_session_id, run.parent_operation_id, run.agent_id,
      run.task, run.status, run.provider, run.model].join(" "),
  }
}

export function subagentRunDetails(run: SubagentRunView): string {
  const lines = [
    `Status: ${run.status}${run.cancel_requested ? " (cancellation requested)" : ""}`,
    `Role: ${run.agent_id}`,
    `Model: ${run.provider}/${run.model}`,
    `Task: ${run.task}`,
    `Run: ${run.id}`,
    `Child session: ${run.child_session_id}`,
    `Parent operation: ${run.parent_operation_id}`,
    `Workspace ready: ${run.workspace_ready ? "yes" : "no"}`,
    `Workspace started: ${run.workspace_started ? "yes" : "no"}`,
    `Result delivered: ${run.outcome_claimed ? "yes" : "no"}`,
  ]
  lines.push(`Workspace base: ${run.workspace_base_commit || "unavailable"}`)
  if (run.result) lines.push(`Result:\n${run.result}`)
  if (run.error) lines.push(`Error:\n${run.error}`)
  lines.push("Provider-reported usage: unavailable")
  return lines.join("\n")
}

export function subagentCanCancel(run: SubagentRunView): boolean {
  return (run.status === "queued" || run.status === "running") && !run.cancel_requested
}
