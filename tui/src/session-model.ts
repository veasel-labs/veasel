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
