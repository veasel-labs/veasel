/** @jsxImportSource @opentui/solid */
import {
  formatModelCatalogCostBadge,
  type ModelCatalogEntry,
} from "../../model-providers"
import type { useDialog } from "../ui/dialog"
import { openDialogSelect } from "../ui/dialog-select"
import type { DialogSelectOption } from "../ui/dialog-select-filter"

export type SolidModelRef = {
  providerID: string
  modelID: string
  name: string
  providerName?: string
  costBadge?: string
}

export type ModelDialogProps = {
  models: SolidModelRef[]
  favorites?: SolidModelRef[]
  recents?: SolidModelRef[]
  current?: SolidModelRef
  onSelect: (model: SolidModelRef) => void
}

export function modelPreferenceKey(model: Pick<SolidModelRef, "providerID" | "modelID">): string {
  return `${model.providerID}/${model.modelID}`
}

/** Demo catalog for Solid shell / testRender until HTTP catalog wiring lands. */
export function demoModels(): SolidModelRef[] {
  return [
    {
      providerID: "anthropic",
      modelID: "claude-sonnet-4",
      name: "Claude Sonnet 4",
      providerName: "Anthropic",
      costBadge: "3/15 $/MTok in/out (pinned)",
    },
    {
      providerID: "openai",
      modelID: "gpt-5",
      name: "GPT-5",
      providerName: "OpenAI",
      costBadge: "5/15 $/MTok in/out (pinned)",
    },
    {
      providerID: "google",
      modelID: "gemini-2.5-pro",
      name: "Gemini 2.5 Pro",
      providerName: "Google",
    },
    {
      providerID: "deepseek",
      modelID: "deepseek-chat",
      name: "DeepSeek Chat",
      providerName: "DeepSeek",
    },
  ]
}

export function demoFavoriteModels(): SolidModelRef[] {
  return [demoModels()[0]!]
}

export function demoRecentModels(): SolidModelRef[] {
  return [demoModels()[1]!, demoModels()[2]!]
}

export function catalogEntryToSolidModel(
  providerID: string,
  providerName: string,
  model: ModelCatalogEntry,
): SolidModelRef {
  return {
    providerID,
    modelID: model.id,
    name: model.name,
    providerName,
    costBadge: formatModelCatalogCostBadge(model) || undefined,
  }
}

function toOption(
  model: SolidModelRef,
  category: string,
  favoriteKeys: Set<string>,
): DialogSelectOption<string> {
  const key = modelPreferenceKey(model)
  const favorite = favoriteKeys.has(key)
  return {
    title: model.name,
    value: key,
    category,
    description: favorite && category !== "Favorites" ? "(Favorite)" : model.providerName,
    footer: model.costBadge,
    searchText: `${model.providerID} ${model.modelID} ${model.providerName ?? ""}`,
  }
}

export function buildModelSelectOptions(props: {
  models: SolidModelRef[]
  favorites?: SolidModelRef[]
  recents?: SolidModelRef[]
}): DialogSelectOption<string>[] {
  const favorites = props.favorites ?? []
  const recents = props.recents ?? []
  const favKeys = new Set(favorites.map(modelPreferenceKey))
  const favOpts = favorites.map((model) => toOption(model, "Favorites", favKeys))
  const recentOpts = recents
    .filter((model) => !favKeys.has(modelPreferenceKey(model)))
    .map((model) => toOption(model, "Recent", favKeys))
  const used = new Set([...favorites, ...recents].map(modelPreferenceKey))
  const rest = props.models
    .filter((model) => !used.has(modelPreferenceKey(model)))
    .map((model) => toOption(model, model.providerName ?? model.providerID, favKeys))
  return [...favOpts, ...recentOpts, ...rest]
}

export function openModelDialog(
  dialog: ReturnType<typeof useDialog>,
  props: ModelDialogProps,
) {
  const options = buildModelSelectOptions(props)
  const byKey = new Map(
    [...(props.favorites ?? []), ...(props.recents ?? []), ...props.models].map((model) => [
      modelPreferenceKey(model),
      model,
    ]),
  )
  openDialogSelect(dialog, {
    title: "Select model",
    placeholder: "Filter models…",
    size: "large",
    current: props.current ? modelPreferenceKey(props.current) : undefined,
    options,
    onSelect: (option) => {
      const model = byKey.get(option.value)
      if (model) props.onSelect(model)
    },
    footer: "Enter selects · Favorites / Recent when present",
  })
}
