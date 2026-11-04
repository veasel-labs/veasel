/** @jsxImportSource @opentui/solid */
import { For, Show, createMemo, createSignal, onMount } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { InputRenderable, KeyEvent } from "@opentui/core"
import {
  filterModelProviders,
  moveProviderPickerScope,
  providerConnectionGuidance,
  providerPickerScopeLabel,
  type ModelProvider,
  type ProviderPickerScope,
} from "../../model-providers"
import {
  formatSettingsListStatus,
  moveSettingsListIndex,
  settingsModeIntro,
  settingsProviderStepPrompt,
  type SettingsWizardMode,
} from "../../settings-flow"
import { DialogHeader, useDialog, type DialogHost } from "../ui/dialog"
import { useSolidTheme } from "../theme"

const LIST_PAGE = 12

/** Visible slice start so the focused row stays on-screen. */
export function providerListWindowStart(
  selected: number,
  count: number,
  pageSize = LIST_PAGE,
): number {
  if (count <= pageSize) return 0
  const half = Math.floor(pageSize / 2)
  const maxStart = count - pageSize
  return Math.min(Math.max(0, selected - half), maxStart)
}

export type ProviderSettingsDialogProps = {
  providers: ModelProvider[]
  configuredProviders?: string[]
  activeProvider?: string
  /** Quick connect vs full provider cockpit — title and intro copy. */
  mode?: SettingsWizardMode
  onSelect?: (provider: ModelProvider) => void
  onStatus?: (status: string) => void
  onCancel?: () => void
}

/**
 * Live provider picker for the Solid home path (`/connect`, `s` / MODEL SETTINGS).
 * Reuses classic filterModelProviders so typo-tolerant search (e.g. anthorpic)
 * matches Anthropic the same way CI smoke expects.
 */
export function ProviderSettingsDialog(props: ProviderSettingsDialogProps) {
  const colors = useSolidTheme()
  const dialog = useDialog()
  const mode = () => props.mode ?? "models"
  const [query, setQuery] = createSignal("")
  const [scope, setScope] = createSignal<ProviderPickerScope>("all")
  const [selected, setSelected] = createSignal(0)
  let filterInput: InputRenderable | undefined

  const configured = () => new Set(props.configuredProviders ?? [])
  const catalog = () => props.providers
  const matches = createMemo(() =>
    filterModelProviders(catalog(), query(), scope(), configured()),
  )

  const scopeLabel = () => providerPickerScopeLabel(scope())
  const countLabel = () => `${scopeLabel()} ${matches().length}/${catalog().length}`
  const statusLine = createMemo(() =>
    formatSettingsListStatus(selected(), matches().length, countLabel()),
  )
  const windowStart = createMemo(() =>
    providerListWindowStart(selected(), matches().length, LIST_PAGE),
  )
  const visible = createMemo(() =>
    matches().slice(windowStart(), windowStart() + LIST_PAGE),
  )
  const selectedProvider = createMemo(() => matches()[selected()])
  const connectionGuidance = createMemo(() => {
    const provider = selectedProvider()
    return provider ? providerConnectionGuidance(provider) : undefined
  })

  const title = () => (mode() === "connect" ? "CONNECT" : "MODEL SETTINGS")
  const hint = () => "Tab · ↑/↓ · Ctrl+L · Esc"

  const publishStatus = () => {
    props.onStatus?.(statusLine())
  }

  onMount(() => {
    const active = props.activeProvider
    if (active) {
      const index = matches().findIndex((provider) => provider.id === active)
      if (index >= 0) setSelected(index)
    }
    publishStatus()
    queueMicrotask(() => filterInput?.focus())
  })

  const jump = (
    where: "up" | "down" | "home" | "end" | "pageup" | "pagedown",
  ) => {
    const count = matches().length
    if (count === 0) return
    setSelected((current) => moveSettingsListIndex(current, count, where, LIST_PAGE))
    queueMicrotask(publishStatus)
  }

  const clearFilter = () => {
    if (query().length === 0) return
    setQuery("")
    setSelected(0)
    filterInput?.setText("")
    queueMicrotask(publishStatus)
  }

  const submit = () => {
    const provider = matches()[selected()]
    if (!provider) return
    // onSelect typically dialog.replace()s the API-key / follow-up prompt.
    // Clearing after that would wipe the next dialog (broken /connect paste flow).
    if (props.onSelect) {
      props.onSelect(provider)
      return
    }
    dialog.clear()
  }

  const selectAt = (absoluteIndex: number) => {
    setSelected(absoluteIndex)
    queueMicrotask(publishStatus)
    submit()
  }

  useKeyboard((key: KeyEvent) => {
    if (key.name === "tab") {
      key.preventDefault()
      setScope((current) => moveProviderPickerScope(current, key.shift ? -1 : 1))
      setSelected(0)
      queueMicrotask(publishStatus)
      return
    }
    if (key.ctrl && key.name === "l" && !key.meta) {
      key.preventDefault()
      clearFilter()
      return
    }
    if (key.name === "up") {
      key.preventDefault()
      jump("up")
      return
    }
    if (key.name === "down") {
      key.preventDefault()
      jump("down")
      return
    }
    // Printable keys belong to the focused search field, even when it is empty.
    // Use arrows, Home/End, and PgUp/PgDn to navigate the provider catalog.
    if (
      key.name === "home"
      || key.name === "end"
      || key.name === "pageup"
      || key.name === "pagedown"
    ) {
      key.preventDefault()
      jump(key.name)
      return
    }
    if (key.name === "return" || key.name === "kpenter") {
      key.preventDefault()
      submit()
      return
    }
    if (key.name === "escape") {
      key.preventDefault()
      props.onCancel?.()
      dialog.clear()
    }
  })

  return (
    <box width="100%" flexDirection="column" gap={1}>
      <DialogHeader title={title()} hint={hint()} />
      <text fg={colors.localStatus}>{statusLine()}</text>
      <text fg={colors.muted}>{settingsProviderStepPrompt(mode())}</text>
      <text fg={colors.muted}>{settingsModeIntro(mode())}</text>
      <text fg={colors.muted}>
        {countLabel()} · type to filter · Tab cycles All / Configured / Local
      </text>
      <input
        ref={(next: InputRenderable) => {
          filterInput = next
        }}
        width="100%"
        focused={true}
        value={query()}
        placeholder="Filter providers…"
        placeholderColor={colors.muted}
        textColor={colors.inputText}
        focusedTextColor={colors.inputText}
        backgroundColor={colors.inputBg}
        focusedBackgroundColor={colors.inputFocusBg}
        cursorColor={colors.cursor}
        onInput={(value: string) => {
          setQuery(value)
          setSelected(0)
          queueMicrotask(publishStatus)
        }}
      />
      <Show when={connectionGuidance()}>
        {(guidance) => (
          <box width="100%" flexDirection="column">
            <text fg={colors.body}>{guidance()}</text>
            <Show when={selectedProvider()?.documentation_url}>
              {(url) => <text fg={colors.muted}>Docs: {url()}</text>}
            </Show>
          </box>
        )}
      </Show>
      <Show
        when={matches().length > 0}
        fallback={<text fg={colors.muted}>No providers match</text>}
      >
        <box width="100%" flexDirection="column">
          <For each={visible()}>
            {(provider, index) => {
              const absolute = () => windowStart() + index()
              const active = () => absolute() === selected()
              return (
                <box
                  width="100%"
                  flexDirection="row"
                  backgroundColor={active() ? colors.inputFocusBg : colors.panelBg}
                  paddingLeft={1}
                  paddingRight={1}
                  onMouseUp={() => selectAt(absolute())}
                >
                  <text fg={active() ? colors.brand : colors.body} flexShrink={0} wrapMode="none">
                    {active() ? "▸ " : "  "}
                    {provider.name}
                  </text>
                  <text fg={colors.muted} flexShrink={1} wrapMode="none">  {provider.id}</text>
                </box>
              )
            }}
          </For>
          <Show when={matches().length > LIST_PAGE}>
            <text fg={colors.muted}>
              Showing {windowStart() + 1}–{Math.min(windowStart() + LIST_PAGE, matches().length)} of{" "}
              {matches().length}
            </text>
          </Show>
        </box>
      </Show>
    </box>
  )
}

export function openProviderSettingsDialog(
  dialog: DialogHost,
  props: ProviderSettingsDialogProps,
) {
  dialog.replace(() => <ProviderSettingsDialog {...props} />, { size: "large" })
}
