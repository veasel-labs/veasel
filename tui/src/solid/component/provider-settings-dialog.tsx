/** @jsxImportSource @opentui/solid */
import { For, Show, createMemo, createSignal, onMount } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { InputRenderable, KeyEvent } from "@opentui/core"
import {
  filterModelProviders,
  moveProviderPickerScope,
  providerPickerScopeLabel,
  type ModelProvider,
  type ProviderPickerScope,
} from "../../model-providers"
import { formatSettingsListStatus } from "../../settings-flow"
import { DialogHeader, useDialog, type DialogHost } from "../ui/dialog"
import { solidMint } from "../theme"

export type ProviderSettingsDialogProps = {
  providers: ModelProvider[]
  configuredProviders?: string[]
  activeProvider?: string
  onSelect?: (provider: ModelProvider) => void
  onStatus?: (status: string) => void
  onCancel?: () => void
}

/**
 * Live provider picker for the Solid home path (`s` / MODEL SETTINGS).
 * Reuses classic filterModelProviders so typo-tolerant search (e.g. anthorpic)
 * matches Anthropic the same way CI smoke expects.
 */
export function ProviderSettingsDialog(props: ProviderSettingsDialogProps) {
  const dialog = useDialog()
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

  const move = (delta: number) => {
    const count = matches().length
    if (count === 0) return
    setSelected((current) => {
      const next = (current + delta + count) % count
      return next
    })
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

  useKeyboard((key: KeyEvent) => {
    if (key.name === "tab") {
      key.preventDefault()
      setScope((current) => moveProviderPickerScope(current, key.shift ? -1 : 1))
      setSelected(0)
      queueMicrotask(publishStatus)
      return
    }
    if (key.name === "up") {
      key.preventDefault()
      move(-1)
      return
    }
    if (key.name === "down") {
      key.preventDefault()
      move(1)
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
      <DialogHeader title="MODEL SETTINGS" hint="Tab scope · type · Esc" />
      <text fg={solidMint.localStatus}>{statusLine()}</text>
      <text fg={solidMint.muted}>
        {countLabel()} · type to filter · Tab cycles All / Configured / Local
      </text>
      <input
        ref={(next: InputRenderable) => {
          filterInput = next
        }}
        width="100%"
        focused={true}
        placeholder="Filter providers…"
        placeholderColor={solidMint.muted}
        textColor={solidMint.inputText}
        focusedTextColor={solidMint.inputText}
        backgroundColor={solidMint.inputBg}
        focusedBackgroundColor={solidMint.inputFocusBg}
        cursorColor={solidMint.cursor}
        onInput={(value: string) => {
          setQuery(value)
          setSelected(0)
          queueMicrotask(publishStatus)
        }}
      />
      <Show
        when={matches().length > 0}
        fallback={<text fg={solidMint.muted}>No providers match</text>}
      >
        <box width="100%" flexDirection="column">
          <For each={matches().slice(0, 12)}>
            {(provider, index) => {
              const active = () => index() === selected()
              return (
                <box
                  width="100%"
                  flexDirection="row"
                  backgroundColor={active() ? solidMint.inputFocusBg : solidMint.panelBg}
                  paddingLeft={1}
                  paddingRight={1}
                  onMouseUp={() => {
                    if (props.onSelect) {
                      props.onSelect(provider)
                      return
                    }
                    dialog.clear()
                  }}
                >
                  <text fg={active() ? solidMint.brand : solidMint.body}>
                    {active() ? "▸ " : "  "}
                    {provider.name}
                  </text>
                  <text fg={solidMint.muted}>  {provider.id}</text>
                </box>
              )
            }}
          </For>
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
