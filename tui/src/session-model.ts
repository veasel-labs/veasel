// Compact provider/model cue for the idle session status line so the operator
// always knows which profile will answer the next prompt.

export type ActiveModelView = {
  active_provider?: string
  profiles?: Record<string, { model?: string }>
}

export function formatActiveModelLabel(view: ActiveModelView): string | undefined {
  const provider = view.active_provider?.trim()
  if (!provider) return undefined
  const model = view.profiles?.[provider]?.model?.trim()
  if (!model) return provider
  return `${provider}/${model}`
}

export function formatListeningStatus(modelLabel?: string): string {
  if (!modelLabel) return "● connected  ·  listening for activity"
  return `● connected  ·  ${modelLabel}  ·  listening for activity`
}

export type ModelReadinessView = {
  model_ready?: boolean
}

// Only an explicit false from the backend counts: its resolution already
// accounts for saved profiles and environment configuration, while older
// backends omit the field and must not trigger a false setup warning.
export function needsModelSetup(view: ModelReadinessView): boolean {
  return view.model_ready === false
}

export const NO_MODEL_SETUP_GUIDANCE =
  "No model is configured yet — type /connect to add a provider key and pick a model. Prompts will fail until then."

// Server-persisted per-session choices (epic #689). The TUI never keeps its
// own copy: it renders what the session API returns, so the TUI and Desktop
// always show, and resume, the same provider/model/permission.
export type SessionSettingsView = {
  preferred_provider?: string
  preferred_model?: string
  permission_mode?: string
  last_provider?: string
  last_model?: string
}

function targetLabel(provider?: string, model?: string): string {
  const p = provider?.trim() ?? ""
  const m = model?.trim() ?? ""
  if (!p) return ""
  return m ? `${p}/${m}` : p
}

// One compact line: the chosen target and non-default permission mode, plus
// what actually ran last when that differs from the choice (never implied).
export function formatSessionSettings(view: SessionSettingsView): string {
  const parts: string[] = []
  const chosen = targetLabel(view.preferred_provider, view.preferred_model)
  parts.push(chosen || "default model")
  const mode = view.permission_mode?.trim()
  if (mode === "bypass") parts.push("bypass permissions!")
  else if (mode && mode !== "ask") parts.push(mode)
  const last = targetLabel(view.last_provider, view.last_model)
  if (last && last !== chosen) parts.push(`last ran ${last}`)
  return parts.join(" · ")
}
