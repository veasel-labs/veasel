/** @jsxImportSource @opentui/solid */
import type { useDialog } from "../ui/dialog"
import type { ApiCliProvider } from "../../api-client"
import { safeModelCatalogText } from "../../model-providers"
import { openDialogSelect } from "../ui/dialog-select"

function authSummary(provider: ApiCliProvider): string {
  if (provider.auth_state === "verified") {
    if (provider.auth_method === "claude.ai") {
      const plan = provider.account_mode ? ` · ${provider.account_mode.toUpperCase()} plan` : ""
      return `signed in with Claude.ai${plan}; quota unknown`
    }
    if (provider.auth_method === "chatgpt") return "signed in with ChatGPT; plan and quota unknown"
    if (provider.auth_method === "api-key") return "CLI reports API-key auth; billing and quota unknown"
    if (provider.auth_method === "console") return "signed in with Claude Console; quota unknown"
    return "sign-in verified by native CLI; plan and quota unknown"
  }
  if (provider.auth_state === "signed-out") return "native CLI reports signed out"
  if (provider.auth_error === "status-command-timeout") return "sign-in check timed out; state unknown"
  if (provider.auth_error) return "native sign-in check failed; state unknown"
  if (provider.auth_state === "probe-present") return "credentials detected; sign-in unverified"
  if (provider.auth_state === "probe-missing") return "no credential file detected; sign-in may still use another method"
  return "sign-in state unknown"
}

export function cliProviderOptions(providers: ApiCliProvider[], permissionMode = "ask") {
  const installed = providers.filter((provider) => provider.installed)
  const defaultOption = {
    title: "Default model provider",
    value: "",
    description: "Use the configured Veasel model provider for this session.",
    searchText: "default model HTTP provider",
  }
  if (installed.length === 0) {
    return [
      defaultOption,
      {
        title: "No installed CLI providers detected",
        value: "__none__",
        description: "Install Claude Code, Codex, OpenCode, or Muse and reopen this picker.",
        disabled: true,
      },
    ]
  }
  return [
    defaultOption,
    ...installed.map((provider) => {
      const mode = permissionMode
      const supportsMode = provider.permission_modes.includes(mode)
      return {
        title: provider.name,
        value: provider.id,
        description: [
          safeModelCatalogText(provider.version) || "version unavailable",
          authSummary(provider),
          `permissions: ${provider.permission_modes.join(", ") || "none"}`,
          ...(!supportsMode ? [`unavailable in ${mode} mode`] : []),
        ].join(" · "),
        searchText: `${provider.id} ${provider.exec} ${provider.protocol}`,
        disabled: !supportsMode,
      }
    }),
  ]
}

export function openCliProviderDialog(
  dialog: ReturnType<typeof useDialog>,
  props: {
    providers: ApiCliProvider[]
    current?: string
    permissionMode?: string
    onSelect: (provider: string) => void
    onCancel?: () => void
  },
) {
  openDialogSelect(dialog, {
    title: "Choose session runner",
    placeholder: "Filter installed CLI providers…",
    current: props.current ?? "",
    options: cliProviderOptions(props.providers, props.permissionMode),
    onSelect: (option) => {
      if (option.value !== "__none__") props.onSelect(option.value)
    },
    onCancel: props.onCancel,
  })
}
