import type { useDialog } from "../ui/dialog"
import { openDialogAlert } from "../ui/dialog-alert"
import { openDialogSelect } from "../ui/dialog-select"
import type { ApiSessionOperation } from "../../api-client"
import { formatTokenCount } from "../../usage"

function operationTitle(operation: ApiSessionOperation): string {
  const model = [operation.provider, operation.model].filter(Boolean).join("/") || "Model unavailable"
  return `${operation.status.toUpperCase()} · ${model}`
}

function operationUsage(operation: ApiSessionOperation): string | undefined {
  if (!operation.usage_reported) return undefined
  return `${formatTokenCount(operation.input_tokens ?? 0)} in · ${formatTokenCount(operation.output_tokens ?? 0)} out`
}

function operationDetails(operation: ApiSessionOperation): string {
  const lines = [
    `Status: ${operation.status}`,
    `Model: ${[operation.provider, operation.model].filter(Boolean).join("/") || "unavailable"}`,
    `Started: ${operation.created_at}`,
    `Updated: ${operation.updated_at}`,
    `Operation: ${operation.id}`,
  ]
  const usage = operationUsage(operation)
  lines.push(`Provider-reported usage: ${usage ?? "unavailable"}`)
  if (operation.cache_reported) {
    lines.push(`Cache: ${formatTokenCount(operation.cache_read_tokens ?? 0)} read · ${formatTokenCount(operation.cache_creation_tokens ?? 0)} written`)
  }
  if (operation.reasoning_reported) {
    lines.push(`Reasoning: ${formatTokenCount(operation.reasoning_tokens ?? 0)} tokens`)
  }
  if (operation.error) lines.push(`Error: ${operation.error}`)
  return lines.join("\n")
}

export function openExecutionHistoryDialog(
  dialog: ReturnType<typeof useDialog>,
  operations: ApiSessionOperation[],
) {
  const recent = [...operations].reverse()
  const options = recent.length > 0
    ? recent.map((operation) => ({
        title: operationTitle(operation),
        value: operation.id,
        description: `${operation.created_at} · ${operation.id.slice(0, 8)}`,
        footer: operationUsage(operation),
        searchText: `${operation.id} ${operation.error} ${operation.status}`,
      }))
    : [{ title: "No executions yet", value: "empty", description: "Completed and interrupted turns will appear here" }]

  openDialogSelect(dialog, {
    title: `Executions · ${recent.length}`,
    options,
    size: "large",
    placeholder: "Filter executions…",
    footer: "Newest first · up to 200 retained terminal runs plus active jobs",
    dismissOnSelect: false,
    onSelect: (option) => {
      const operation = recent.find((item) => item.id === option.value)
      if (!operation) return
      openDialogAlert(dialog, {
        title: "Execution details",
        message: operationDetails(operation),
        confirmLabel: "close",
      })
    },
  })
}
