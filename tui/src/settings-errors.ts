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

export function formatProviderConnectionError(provider: string, raw: string): string {
  const message = raw.replace(/\s+/g, " ").trim().replace(/\.$/, "") || "model discovery failed"
  const providerID = provider.toLowerCase()
  if (providerID !== "opencode" && providerID !== "opencode-go") return message

  const status = /\b(?:http\s*)?(401|403|429)\b/i.exec(message)?.[1]
  if (status === "401") {
    return "OpenCode rejected this API key (HTTP 401). If it expired, create a new key in OpenCode Console; signing in again will not renew it."
  }
  if (status === "403") {
    const access = providerID === "opencode-go"
      ? "Check your Go subscription and whether this model is available to your account."
      : "Check whether your account can use this model."
    return `OpenCode denied access (HTTP 403). ${access}`
  }
  if (status === "429") {
    return "OpenCode rate-limited this request (HTTP 429). Check your usage limits, wait, then retry."
  }
  return message
}

export function formatSettingsLoadError(raw: string): string {
  const message = raw.replace(/\s+/g, " ").trim().replace(/\.$/, "") || "settings API unavailable"
  return `✖ could not load model settings · ${message}`
}
