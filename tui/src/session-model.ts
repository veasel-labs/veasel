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
