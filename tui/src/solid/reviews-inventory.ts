import type {
  ApiMcpToolCallApproval,
  ApiCliToolApproval,
  ApiShellCommandSummary,
  ApiWorkspaceEditProposal,
  VeaselApiClient,
} from "../api-client"
import type { ActiveReview } from "../active-review"
import type { ReviewSandboxPreview } from "../shell-review"
import { cliApprovalInputPreview } from "../cli-approval-review"
import type { ReviewDecision, ReviewDecisionResult, SolidReviewItem } from "./reviews"

/** Inventory only: detail GETs record inspection and must wait until an item is opened. */
export async function loadPendingSolidReviews(
  api: VeaselApiClient,
  sessionId: string,
): Promise<SolidReviewItem[]> {
  const [edits, commands, calls, cliApprovals] = await Promise.all([
    api.listWorkspaceEdits(sessionId),
    api.listWorkspaceCommands(sessionId),
    api.listMcpToolCalls(sessionId),
    api.listCliToolApprovals(sessionId),
  ])
  const pendingEdits = edits.filter((item) => item.status === "pending")
  const pendingCommands = commands.filter((item) => item.status === "pending")
  const pendingCalls = calls.filter((item) => item.status === "pending")
  const pendingCliApprovals = cliApprovals.filter((item) => item.status === "pending")

  return [
    ...pendingEdits.map((item) => ({ ...solidPatchFromEdit({ ...item, diff: "" }), inspected: false })),
    ...pendingCommands.map((item) => ({ ...solidCommandFromSummary(item), inspected: false })),
    ...pendingCalls.map((item) => ({ ...solidMcpFromApproval({ ...item, arguments_json: "" }), inspected: false })),
    ...pendingCliApprovals.map((item) => ({ ...solidCliFromApproval(item), inspected: false })),
  ]
}

export async function inspectSolidReview(
  api: VeaselApiClient,
  sessionId: string,
  target: ActiveReview,
): Promise<SolidReviewItem> {
  let item: SolidReviewItem
  if (target.kind === "patch") {
    item = solidPatchFromEdit(await api.getWorkspaceEdit(sessionId, target.id))
  } else if (target.kind === "command") {
    item = solidCommandFromSummary(await api.getWorkspaceCommand(sessionId, target.id))
  } else if (target.kind === "mcp") {
    item = solidMcpFromApproval(await api.getMcpToolCall(sessionId, target.id))
  } else {
    const approval = (await api.listCliToolApprovals(sessionId)).find((item) => item.id === target.id)
    if (!approval) throw new Error("Installed CLI approval is no longer pending")
    item = solidCliFromApproval(approval)
  }
  return { ...item, inspected: true }
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

export function solidCliFromApproval(approval: ApiCliToolApproval): SolidReviewItem {
  const preview = cliApprovalInputPreview(approval.input_json)
  return {
    kind: "cli",
    id: approval.id,
    pending: approval.status === "pending",
    toolName: approval.tool_name,
    requestId: approval.request_id,
    argumentsText: preview.text,
    inputFullyVisible: preview.fullyVisible,
  }
}

export async function decideSolidReviews(
  api: VeaselApiClient,
  sessionId: string,
  decision: ReviewDecision,
  targets: ActiveReview[],
): Promise<ReviewDecisionResult> {
  if (decision === "approve" && targets.some((target) => target.kind === "cli") && targets.length !== 1) {
    return { settled: [], failed: ["Installed CLI requests must be approved one at a time."] }
  }
  const settled: ActiveReview[] = []
  const failed: string[] = []
  for (const target of targets) {
    try {
      if (target.kind === "patch") {
        await api.decideWorkspaceEdit(sessionId, target.id, decision)
      } else if (target.kind === "command") {
        await api.decideWorkspaceCommand(sessionId, target.id, decision)
      } else if (target.kind === "mcp") {
        await api.decideMcpToolCall(sessionId, target.id, decision)
      } else {
        await api.decideCliToolApproval(sessionId, target.id, decision)
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
