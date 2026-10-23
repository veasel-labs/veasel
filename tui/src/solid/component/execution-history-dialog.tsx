import type { useDialog } from "../ui/dialog"
import { openDialogAlert } from "../ui/dialog-alert"
import { openDialogSelect } from "../ui/dialog-select"
import type { ApiGlobalSessionOperation, ApiSessionOperation } from "../../api-client"
import { formatTokenCount } from "../../usage"

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
  entries: ApiGlobalSessionOperation[],
  nextBefore?: string,
  onLoadMore?: (cursor: string) => void,
) {
  const recent = entries
  const options = recent.length > 0
    ? recent.map((entry) => ({
        title: entry.operation.status.toUpperCase(),
        value: entry.operation.id,
        description: `${entry.session_title} · ${[entry.operation.provider, entry.operation.model].filter(Boolean).join("/") || "Model unavailable"} · ${entry.operation.created_at} · ${entry.operation.id.slice(0, 8)}`,
        footer: operationUsage(entry.operation),
        searchText: `${entry.operation.id} ${entry.operation.error} ${entry.operation.status} ${entry.session_title}`,
      }))
    : [{
        title: "No executions yet",
        value: "empty",
        description: "Completed and interrupted turns will appear here",
        footer: undefined,
        searchText: "",
      }]
  if (nextBefore) {
    options.push({
      title: "Load older executions…",
      value: "__load_older__",
      description: "Fetch the next page from durable history",
      footer: undefined,
      searchText: "",
    })
  }

  openDialogSelect(dialog, {
    title: `All executions · ${recent.length}`,
    options,
    size: "large",
    placeholder: "Filter executions…",
    footer: nextBefore ? "Newest first · select Load older to continue · Esc closes" : "Newest first · Esc closes",
    dismissOnSelect: false,
    onSelect: (option) => {
      if (option.value === "__load_older__" && nextBefore) {
        onLoadMore?.(nextBefore)
        return
      }
      const entry = recent.find((item) => item.operation.id === option.value)
      if (!entry) return
      openDialogAlert(dialog, {
        title: "Execution details",
        message: `Session: ${entry.session_title}\n${operationDetails(entry.operation)}`,
        confirmLabel: "close",
      })
    },
  })
}
