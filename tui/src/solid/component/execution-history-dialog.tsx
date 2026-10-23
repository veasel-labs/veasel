import { createMemo, createSignal, onCleanup, onMount } from "solid-js"
import { useDialog, type DialogHost } from "../ui/dialog"
import { openDialogAlert } from "../ui/dialog-alert"
import { DialogSelect, type DialogSelectOption } from "../ui/dialog-select"
import type { ApiGlobalSessionOperation, ApiSessionOperation, VeaselApiClient } from "../../api-client"
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

function ExecutionHistoryDialog(props: { api: VeaselApiClient }) {
  const dialog = useDialog()
  const [entries, setEntries] = createSignal<ApiGlobalSessionOperation[]>([])
  const [nextBefore, setNextBefore] = createSignal<string>()
  const [query, setQuery] = createSignal("")
  const [loading, setLoading] = createSignal(false)
  const [error, setError] = createSignal<string>()
  let revision = 0
  let debounce: ReturnType<typeof setTimeout> | undefined

  const load = async (search: string, cursor: string | undefined, append: boolean, expectedRevision: number) => {
    setLoading(true)
    setError(undefined)
    try {
      const page = await props.api.listGlobalOperations({ before: cursor, limit: 50, search })
      if (expectedRevision !== revision) return
      setEntries((current) => append ? [...current, ...page.operations] : page.operations)
      setNextBefore(page.next_before)
    } catch (cause) {
      if (expectedRevision !== revision) return
      setError(cause instanceof Error ? cause.message : "Could not search execution history.")
      if (!append) {
        setEntries([])
        setNextBefore(undefined)
      }
    } finally {
      if (expectedRevision === revision) setLoading(false)
    }
  }

  const search = (value: string) => {
    const normalized = value.trim()
    setQuery(normalized)
    revision += 1
    const requestRevision = revision
    if (debounce) clearTimeout(debounce)
    setEntries([])
    setNextBefore(undefined)
    setError(undefined)
    setLoading(true)
    debounce = setTimeout(() => {
      void load(normalized, undefined, false, requestRevision)
    }, normalized ? 250 : 0)
  }

  const options = createMemo(() => {
    const recent = entries()
    const result: DialogSelectOption<string>[] = recent.length > 0
      ? recent.map((entry) => ({
        title: entry.operation.status.toUpperCase(),
        value: entry.operation.id,
        description: `${entry.session_title} · ${[entry.operation.provider, entry.operation.model].filter(Boolean).join("/") || "Model unavailable"} · ${entry.operation.created_at} · ${entry.operation.id.slice(0, 8)}`,
        footer: operationUsage(entry.operation),
        searchText: `${entry.operation.id} ${entry.operation.error} ${entry.operation.status} ${entry.operation.provider} ${entry.operation.model} ${entry.session_title}`,
      }))
      : loading()
        ? [{ title: "Searching…", value: "loading", description: "Looking across durable execution history", searchText: "" }]
        : [{ title: query() ? "No matching executions" : "No executions yet", value: "empty", description: query() ? "Try a session, model, status, operation id, or error" : "Completed and interrupted turns will appear here", searchText: "" }]
    if (nextBefore() && !loading()) result.push({
      title: "Load older executions…",
      value: "__load_older__",
      description: query() ? "Fetch the next matching page" : "Fetch the next page from durable history",
      searchText: "",
    })
    return result
  })

  onMount(() => {
    void load("", undefined, false, revision)
  })
  onCleanup(() => {
    revision += 1
    if (debounce) clearTimeout(debounce)
  })

  return <DialogSelect
    title={`All executions · ${entries().length}`}
    options={options()}
    placeholder="Search all executions…"
    footer={error() ?? (loading() ? "Searching durable history…" : nextBefore() ? "Search all sessions · select Load older to continue · Esc closes" : "Search all sessions · newest first · Esc closes")}
    dismissOnSelect={false}
    onQueryChange={search}
    onSelect={(option) => {
      if (option.value === "__load_older__" && nextBefore()) {
        void load(query(), nextBefore(), true, revision)
        return
      }
      const entry = entries().find((item) => item.operation.id === option.value)
      if (!entry) return
      openDialogAlert(dialog, {
        title: "Execution details",
        message: `Session: ${entry.session_title}\n${operationDetails(entry.operation)}`,
        confirmLabel: "close",
      })
    }}
  />
}

export function openExecutionHistoryDialog(dialog: DialogHost, api: VeaselApiClient) {
  dialog.replace(() => <ExecutionHistoryDialog api={api} />, { size: "large" })
}
