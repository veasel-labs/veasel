export type SettingsProvider = {
  base_url: string
  requires_api_key: boolean
}

export const providerStep = 0
export const endpointStep = 1
export const credentialStep = 2
export const modelStep = 3
export const budgetStep = 4

// Known catalog endpoints are used as-is. Ordinary setup should not ask the
// user to retype them. An empty or unparseable URL still needs the endpoint step.
export function providerHasKnownEndpoint(provider: { base_url: string }): boolean {
  if (/[{}$]|YOUR_ACCOUNT_ID/i.test(provider.base_url)) return false
  try {
    const url = new URL(provider.base_url)
    return (url.protocol === "https:" || url.protocol === "http:") && url.hostname.length > 0
  } catch {
    return false
  }
}

export function endpointHost(baseUrl: string): string {
  try {
    return new URL(baseUrl).host
  } catch {
    return ""
  }
}

// Visible wizard steps. The endpoint step appears only for an unknown URL or
// when the user explicitly asks to change it. The key step appears only when
// the provider requires a credential.
export function settingsPath(
  provider: SettingsProvider | undefined,
  options: { editEndpoint?: boolean; editBudget?: boolean } = {},
): number[] {
  const steps = [providerStep]
  const known = provider ? providerHasKnownEndpoint(provider) : false
  if (!known || options.editEndpoint) steps.push(endpointStep)
  if (!provider || provider.requires_api_key) steps.push(credentialStep)
  steps.push(modelStep)
  if (options.editBudget) steps.push(budgetStep)
  return steps
}

export function adjacentSettingsStep(path: number[], current: number, direction: 1 | -1): number {
  const index = path.indexOf(current)
  if (index < 0) return path[0] ?? current
  const next = index + direction
  if (next < 0 || next >= path.length) return current
  return path[next] ?? current
}

// Ctrl+U and Ctrl+O open the endpoint or budget as a side trip. Back returns to
// the step that opened the trip and drops the trip from the path. A provider
// that already requires that step keeps the normal path order.
export function settingsBackTarget(
  path: number[],
  current: number,
  detourFrom: number | undefined,
): { step: number; cancelDetour: boolean } {
  const openedAsDetour = detourFrom !== undefined
    && detourFrom !== current
    && (current === endpointStep || current === budgetStep)
  if (openedAsDetour) return { step: detourFrom, cancelDetour: true }
  return { step: adjacentSettingsStep(path, current, -1), cancelDetour: false }
}

export function settingsProgress(path: number[], current: number): { index: number; total: number } {
  const index = path.indexOf(current)
  return { index: index < 0 ? 1 : index + 1, total: path.length }
}

// Credential-step copy for /connect and /models. Env is an optional alternative;
// saved keys are the primary path and win over env on the server.
export function credentialStepCopy(options: {
  apiKeySaved: boolean
  environmentKey?: string
}): { prompt: string; hint: string } {
  const saved = options.apiKeySaved
    ? "A key is already saved for this provider."
    : "No key is saved for this provider."
  const env = options.environmentKey
    ? ` Or set ${options.environmentKey} on the server process if you prefer not to save a key.`
    : ""
  return {
    prompt: "Paste your API key. Veasel saves it for this provider on this machine.",
    hint: `\n\n${saved} Enter keeps an already-saved key. Type !clear to remove it.${env} Key characters are hidden.`,
  }
}

export type SettingsWizardMode = "connect" | "models"

// Connect is the short auth path; /models (s) is the full provider cockpit.
export function settingsModeIntro(mode: SettingsWizardMode): string {
  if (mode === "connect") {
    return "Quick connect · pick a provider, paste a key if needed, then choose a model. Press s later for endpoint and output-budget controls."
  }
  return "Provider settings · switch providers, override endpoints (Ctrl+U), and set an output budget (Ctrl+O)."
}

export function settingsProviderStepPrompt(mode: SettingsWizardMode): string {
  if (mode === "connect") {
    return "Choose the provider to authenticate. Tab cycles All / Configured / Local / …; type to filter."
  }
  return "Choose a provider. Tab cycles All / Configured / Local / Specialized / OpenAI-compatible; type to filter by name, model, or key."
}

// When the highlighted provider differs from the active profile, say so plainly.
export function providerSwitchNote(
  activeProviderId: string | undefined,
  selectedProviderId: string | undefined,
  selectedProviderName?: string,
): string {
  const active = activeProviderId?.trim()
  const selected = selectedProviderId?.trim()
  if (!active || !selected || active === selected) return ""
  const label = selectedProviderName?.trim() || selected
  return `\n\nSwitching from ${active} → ${label}. Saving replaces the active provider for new turns.`
}

export function settingsFooterHint(step: number, endpoint: boolean, budget: boolean): string {
  if (step === 0) return "Tab · j/k · 1-9 · type · Home/End · Ctrl+L · Esc"
  if (step === 3) return "j/k · 1-9 · type · Home/End · Ctrl+L · Ctrl+B · Esc"
  const parts = [
    step === 2 ? "Enter discovers" : step === 4 ? "Enter saves budget" : step === 1 ? "Enter keeps endpoint" : "Enter selects",
    "Ctrl+B back",
  ]
  if (endpoint) parts.push("Ctrl+U endpoint")
  if (budget) parts.push("Ctrl+O budget")
  parts.push("Esc")
  return parts.join(" · ")
}

// j/k, Home/End, and Pg for provider and model pickers — same edge behavior as
// the home session list so operators transfer muscle memory.
export function moveSettingsListIndex(
  index: number,
  count: number,
  where: "up" | "down" | "home" | "end" | "pageup" | "pagedown",
  pageSize = 5,
): number {
  if (count <= 0) return 0
  const max = count - 1
  const current = Math.min(Math.max(0, index), max)
  const page = Math.max(1, pageSize)
  if (where === "up") return Math.max(0, current - 1)
  if (where === "down") return Math.min(max, current + 1)
  if (where === "home") return 0
  if (where === "end") return max
  if (where === "pageup") return Math.max(0, current - page)
  return Math.min(max, current + page)
}

// Plain-text position cue for provider/model pickers so highlight is not only ●.
export function formatSettingsListStatus(
  selected: number,
  count: number,
  label: string,
): string {
  if (count <= 0) return `● ${label}  ·  none`
  const index = Math.min(Math.max(0, selected), count - 1)
  return `● ${label}  ·  selected ${index + 1} of ${count}`
}

export function homeWorkspaceBlurb(options: {
  providersConfigured: boolean
  modelLabel?: string
}): string {
  if (!options.providersConfigured) {
    return "Your V-powered coding companion.\n\nConnect provider · /connect\nPaste an API key, save it on this machine, then pick a model. Or press s for full provider settings (endpoint, budget)."
  }
  const model = options.modelLabel?.trim()
  const modelLine = model ? `\nActive model · ${model}` : ""
  return `Your V-powered coding companion.${modelLine}\n\nChoose a session on the left, press n to start a workspace, or use /connect · s to manage providers.`
}
