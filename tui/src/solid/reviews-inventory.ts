import type {
  ApiMcpToolCallApproval,
  ApiShellCommandSummary,
  ApiWorkspaceEditProposal,
  VeaselApiClient,
} from "../api-client"
import type { ActiveReview } from "../active-review"
import type { ReviewSandboxPreview } from "../shell-review"
import type { ReviewDecision, ReviewDecisionResult, SolidReviewItem } from "./reviews"

/** Load pending edits / shell / MCP calls with detail GETs (records inspect-before-approve). */
export async function loadPendingSolidReviews(
  api: VeaselApiClient,
  sessionId: string,
): Promise<SolidReviewItem[]> {
  const [edits, commands, calls] = await Promise.all([
    api.listWorkspaceEdits(sessionId),
    api.listWorkspaceCommands(sessionId),
    api.listMcpToolCalls(sessionId),
  ])
  const pendingEdits = edits.filter((item) => item.status === "pending")
  const pendingCommands = commands.filter((item) => item.status === "pending")
  const pendingCalls = calls.filter((item) => item.status === "pending")

  const editDetails = await Promise.all(
    pendingEdits.map((item) => api.getWorkspaceEdit(sessionId, item.id)),
  )
  const commandDetails = await Promise.all(
    pendingCommands.map((item) => api.getWorkspaceCommand(sessionId, item.id)),
  )
  const callDetails = await Promise.all(
    pendingCalls.map((item) => api.getMcpToolCall(sessionId, item.id)),
  )

  return [
    ...editDetails.map(solidPatchFromEdit),
    ...commandDetails.map(solidCommandFromSummary),
    ...callDetails.map(solidMcpFromApproval),
  ]
}

export function solidPatchFromEdit(edit: ApiWorkspaceEditProposal): SolidReviewItem {
  return {
    kind: "patch",
    id: edit.id,
    pending: edit.status === "pending",
    path: edit.path,
    diff: edit.diff ?? "",
    status: edit.status,
  }
}

export function solidCommandFromSummary(item: ApiShellCommandSummary): SolidReviewItem {
  return {
    kind: "command",
    id: item.id,
    pending: item.status === "pending",
    command: item.command,
    cwd: item.cwd,
    timeoutSeconds: item.timeout_seconds,
    runner: process.platform === "win32" ? "COMSPEC" : "/bin/sh",
    output: item.output,
    sandbox: item.sandbox as ReviewSandboxPreview | undefined,
  }
}

export function solidMcpFromApproval(call: ApiMcpToolCallApproval): SolidReviewItem {
  return {
    kind: "mcp",
    id: call.id,
    pending: call.status === "pending",
    plugin: call.plugin_name,
    server: call.server_name,
    tool: call.tool_name,
    operationId: call.operation_id,
    argumentsText: call.arguments_json ?? "",
    stdioSandbox: call.stdio_sandbox as ReviewSandboxPreview | undefined,
  }
}

export async function decideSolidReviews(
  api: VeaselApiClient,
  sessionId: string,
  decision: ReviewDecision,
  targets: ActiveReview[],
): Promise<ReviewDecisionResult> {
  const settled: ActiveReview[] = []
  const failed: string[] = []
  for (const target of targets) {
    try {
      if (target.kind === "patch") {
        await api.decideWorkspaceEdit(sessionId, target.id, decision)
      } else if (target.kind === "command") {
        await api.decideWorkspaceCommand(sessionId, target.id, decision)
      } else {
        await api.decideMcpToolCall(sessionId, target.id, decision)
      }
      settled.push(target)
    } catch (error) {
      failed.push(
        `${target.kind}:${target.id.slice(0, 8)} · ${
          error instanceof Error ? error.message : "request failed"
        }`,
      )
    }
  }
  return { settled, failed }
}
