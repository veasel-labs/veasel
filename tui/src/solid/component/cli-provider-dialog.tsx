/** @jsxImportSource @opentui/solid */
import type { useDialog } from "../ui/dialog"
import type { ApiCliProvider } from "../../api-client"
import { safeModelCatalogText } from "../../model-providers"
import { openDialogSelect } from "../ui/dialog-select"

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
          provider.auth_state === "probe-present"
            ? "auth file detected; sign-in not verified"
            : provider.auth_state === "probe-missing"
              ? "auth file not detected"
              : "auth state unknown",
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
