import { createMemo, createSignal, onMount } from "solid-js"
import { useDialog, type DialogHost } from "../ui/dialog"
import { openDialogAlert } from "../ui/dialog-alert"
import { DialogSelect, type DialogSelectOption } from "../ui/dialog-select"
import type { ApiGlobalUsageModelSummary, ApiGlobalUsageSummary, VeaselApiClient } from "../../api-client"
import { formatTokenCount } from "../../usage"

function modelDetails(model: ApiGlobalUsageModelSummary): string {
  const lines = [
    `Provider: ${model.provider}`,
    `Model: ${model.model}`,
    `Completed turns: ${model.completed_turns} · reported: ${model.reported_turns}`,
    `Provider-reported tokens: ${formatTokenCount(model.input_tokens)} input · ${formatTokenCount(model.output_tokens)} output`,
    ...(model.cache_reported ? [`Cache: ${formatTokenCount(model.cache_read_tokens)} read · ${formatTokenCount(model.cache_creation_tokens)} written · reported on ${model.cache_reported_turns} turns`] : []),
    ...(model.reasoning_reported ? [`Reasoning: ${formatTokenCount(model.reasoning_tokens)} tokens · reported on ${model.reasoning_reported_turns} turns`] : []),
    `Estimated cost (pinned schedule): ${model.cost}`,
  ]
  return lines.join("\n")
}

function UsageDashboardDialog(props: { api: VeaselApiClient }) {
  const dialog = useDialog()
  const [summary, setSummary] = createSignal<ApiGlobalUsageSummary>()
  const [error, setError] = createSignal<string>()
  const [loading, setLoading] = createSignal(true)

  onMount(() => {
    void props.api.getUsage().then(setSummary).catch((cause: unknown) => {
      setError(cause instanceof Error ? cause.message : "Could not load usage.")
    }).finally(() => setLoading(false))
  })

  const options = createMemo((): DialogSelectOption<string>[] => {
    const models = summary()?.models ?? []
    if (models.length === 0) return [{
      title: loading() ? "Loading usage…" : error() ? "Usage unavailable" : "No completed usage yet",
      value: "empty",
      description: error() ?? "Completed turns with provider-reported usage appear here.",
      searchText: "",
    }]
    return models.map((model) => ({
      title: `${model.provider} / ${model.model}`,
      value: `${model.provider}\0${model.model}`,
      description: model.reported_turns > 0
        ? `${formatTokenCount(model.input_tokens)} in · ${formatTokenCount(model.output_tokens)} out · ${model.reported_turns} turns · ${model.cost}`
        : `${model.completed_turns} turns · usage unavailable · ${model.cost}`,
      searchText: `${model.provider} ${model.model}`,
    }))
  })

  return <DialogSelect
    title="Usage by model"
    options={options()}
    placeholder="Filter provider or model…"
    footer={loading() ? "Loading durable usage…" : error() ?? `All sessions · ${summary()?.sessions ?? 0} · ${summary()?.completed_turns ?? 0} completed turns · provider-reported usage · estimated costs use pinned rates`}
    dismissOnSelect={false}
    onSelect={(option) => {
      const model = summary()?.models.find((item) => `${item.provider}\0${item.model}` === option.value)
      if (model) openDialogAlert(dialog, { title: "Usage details", message: modelDetails(model), confirmLabel: "close" })
    }}
  />
}

export function openUsageDashboardDialog(dialog: DialogHost, api: VeaselApiClient) {
  dialog.replace(() => <UsageDashboardDialog api={api} />, { size: "large" })
}
