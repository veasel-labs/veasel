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
  options: { editEndpoint?: boolean } = {},
): number[] {
  const steps = [providerStep]
  const known = provider ? providerHasKnownEndpoint(provider) : false
  if (!known || options.editEndpoint) steps.push(endpointStep)
  if (!provider || provider.requires_api_key) steps.push(credentialStep)
  steps.push(modelStep, budgetStep)
  return steps
}

export function adjacentSettingsStep(path: number[], current: number, direction: 1 | -1): number {
  const index = path.indexOf(current)
  if (index < 0) return path[0] ?? current
  const next = index + direction
  if (next < 0 || next >= path.length) return current
  return path[next] ?? current
}

export function settingsProgress(path: number[], current: number): { index: number; total: number } {
  const index = path.indexOf(current)
  return { index: index < 0 ? 1 : index + 1, total: path.length }
}
