// Actionable settings errors that keep the wizard open so the operator can
// fix the credential, endpoint, or model without restarting /connect.

export function formatSettingsSaveError(raw: string): string {
  const message = raw.replace(/\s+/g, " ").trim().replace(/\.$/, "") || "settings were rejected"
  const lower = message.toLowerCase()
  let tip = "Fix the current step, then Enter again. Esc cancels."
  if (lower.includes("api key") || lower.includes("unauthorized") || lower.includes("401") || lower.includes("credential")) {
    tip = "Check the API key (or !clear), then Enter. Esc cancels."
  } else if (lower.includes("endpoint") || lower.includes("base_url") || lower.includes("url") || lower.includes("dns") || lower.includes("econn")) {
    tip = "Ctrl+U to edit the endpoint, then retry. Esc cancels."
  } else if (lower.includes("model")) {
    tip = "Pick another model or type an ID manually, then retry. Esc cancels."
  }
  return `✖ could not save · ${message}  ·  ${tip}`
}

export function formatSettingsLoadError(raw: string): string {
  const message = raw.replace(/\s+/g, " ").trim().replace(/\.$/, "") || "settings API unavailable"
  return `✖ could not load model settings · ${message}`
}
