/** @jsxImportSource @opentui/solid */
import { For, Show, createEffect, createMemo, createSignal } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { KeyEvent, TextareaRenderable } from "@opentui/core"
import {
  composerHeightForText,
  composerKeyBindings,
  composerMaxHeight,
} from "../composer-input"
import { pathMentionAt } from "../path-autocomplete"
import { skillMentionAt } from "../skill-autocomplete"
import type { SkillCatalogEntry } from "../skill-autocomplete"
import { completeSlashCommand } from "../slash-commands"
import type { SlashCompletionContext } from "../slash-commands"
import { solidMint } from "./theme"
import {
  acceptComposerAutocomplete,
  demoComposerSkills,
  jumpComposerAutocomplete,
  moveComposerAutocomplete,
  resolveComposerAutocomplete,
  windowedComposerItems,
  type ComposerAutocompleteDismissed,
  type ComposerAutocompleteMenu,
} from "./composer-autocomplete"

export type SolidComposerProps = {
  placeholder?: string
  focused?: boolean
  onSubmit?: (text: string) => void
  workspaceRoot?: string
  skills?: SkillCatalogEntry[]
  slashContext?: SlashCompletionContext
  listPaths?: (root: string) => string[]
  /** When this token changes, replace the composer draft (stash restore). */
  restoreToken?: { id: string; text: string }
  /** Latest draft text for stash / external observers. */
  onDraftChange?: (text: string) => void
}

function kindTitle(kind: ComposerAutocompleteMenu["kind"]): string {
  if (kind === "path") return "paths"
  if (kind === "skill") return "skills"
  return "commands"
}

// Reactive multiline composer with `/` `@` `$` autocomplete (classic matchers).
export function SolidComposer(props: SolidComposerProps) {
  const [draft, setDraft] = createSignal("")
  const [selected, setSelected] = createSignal(0)
  const [dismissed, setDismissed] = createSignal<ComposerAutocompleteDismissed | undefined>(undefined)
  let area: TextareaRenderable | undefined
  let lastRestoreId: string | undefined

  const skills = () => props.skills ?? demoComposerSkills()

  createEffect(() => {
    const token = props.restoreToken
    if (!token || token.id === lastRestoreId) return
    lastRestoreId = token.id
    setDraft(token.text)
    setDismissed(undefined)
    setSelected(0)
    if (area) {
      area.setText(token.text)
      area.height = composerHeightForText(token.text)
    }
    props.onDraftChange?.(token.text)
  })

  const menu = createMemo(() => {
    const value = draft()
    const cursor = area?.cursorOffset ?? value.length
    return resolveComposerAutocomplete({
      value,
      cursor,
      skills: skills(),
      slashContext: props.slashContext,
      workspaceRoot: props.workspaceRoot,
      listPaths: props.listPaths,
      dismissed: dismissed(),
      selected: selected(),
    })
  })

  const visibleItems = createMemo(() => {
    const active = menu()
    return active ? windowedComposerItems(active) : []
  })

  // When the menu is open, suspend textarea navigation bindings and claim Esc /
  // Tab / Enter so classic autocomplete chords win (OpenCode prompt traits pattern).
  createEffect(() => {
    if (!area) return
    if (menu()) {
      area.traits = {
        ...area.traits,
        capture: ["escape", "navigate", "submit", "tab"],
        suspend: true,
      }
      return
    }
    area.traits = {
      ...area.traits,
      capture: ["tab"],
      suspend: false,
    }
  })

  const applyEdit = (value: string, cursor: number) => {
    if (!area) {
      setDraft(value)
      setDismissed(undefined)
      setSelected(0)
      return
    }
    area.setText(value)
    area.cursorOffset = cursor
    setDraft(value)
    area.height = composerHeightForText(value)
    setDismissed(undefined)
    setSelected(0)
  }

  const clearComposer = () => {
    area?.setText("")
    setDraft("")
    setSelected(0)
    setDismissed(undefined)
    if (area) area.height = composerHeightForText("")
  }

  const send = (text: string) => {
    if (text.length === 0) return
    props.onSubmit?.(text)
    clearComposer()
  }

  const accept = (mode: "tab" | "enter"): boolean => {
    const value = area?.plainText ?? draft()
    const cursor = area?.cursorOffset ?? value.length
    const active = menu()
    if (!active) return false
    const result = acceptComposerAutocomplete({
      value,
      cursor,
      skills: skills(),
      slashContext: props.slashContext,
      workspaceRoot: props.workspaceRoot,
      listPaths: props.listPaths,
      selected: active.selected,
    })
    if (!result) {
      // Already-complete runnable slash: Enter submits the draft.
      if (mode === "enter" && active.kind === "slash") {
        send(value.trimEnd())
        return true
      }
      return false
    }
    if (result.submit && mode === "enter") {
      applyEdit(result.value, result.cursor)
      send(result.value.trimEnd())
      return true
    }
    applyEdit(result.value, result.cursor)
    return true
  }

  const submit = () => {
    // Textarea Enter binding; when the menu is open, accept instead of send.
    if (menu()) {
      accept("enter")
      return
    }
    send((area?.plainText ?? draft()).trimEnd())
  }

  useKeyboard((key: KeyEvent) => {
    if (!(props.focused ?? true)) return
    const active = menu()
    if (!active) return

    const consume = () => {
      key.preventDefault()
      key.stopPropagation()
    }

    if (key.name === "down") {
      consume()
      setSelected((current) => moveComposerAutocomplete(current, 1, active.items.length))
      return
    }
    if (key.name === "up" || (key.name === "tab" && key.shift)) {
      consume()
      setSelected((current) => moveComposerAutocomplete(current, -1, active.items.length))
      return
    }
    if (key.name === "tab" && !key.shift) {
      consume()
      // Tab completes; once completed, further Tabs cycle (classic parity).
      if (isAlreadyCompleted(active, area?.plainText ?? draft(), area?.cursorOffset ?? draft().length) && active.items.length > 1) {
        setSelected((current) => moveComposerAutocomplete(current, 1, active.items.length))
        return
      }
      accept("tab")
      return
    }
    if (key.name === "home") {
      consume()
      setSelected((current) => jumpComposerAutocomplete(current, active.items.length, "home"))
      return
    }
    if (key.name === "end") {
      consume()
      setSelected((current) => jumpComposerAutocomplete(current, active.items.length, "end"))
      return
    }
    if (key.name === "pageup") {
      consume()
      setSelected((current) => jumpComposerAutocomplete(current, active.items.length, "pageup"))
      return
    }
    if (key.name === "pagedown") {
      consume()
      setSelected((current) => jumpComposerAutocomplete(current, active.items.length, "pagedown"))
      return
    }
    if (key.name === "escape") {
      consume()
      setDismissed({ kind: active.kind, value: area?.plainText ?? draft() })
      return
    }
    if (key.name === "return" || key.name === "kpenter") {
      // Prefer keyboard path so textarea submit does not double-fire.
      consume()
      accept("enter")
    }
  })

  return (
    <box width="100%" flexShrink={0} flexDirection="column" gap={0}>
      <Show when={menu()}>
        {(active) => (
          <box
            width="100%"
            border
            borderColor={solidMint.panelBorder}
            backgroundColor={solidMint.panelBg}
            paddingLeft={1}
            paddingRight={1}
            paddingTop={0}
            paddingBottom={0}
            title={` ${kindTitle(active().kind)} `}
            titleColor={solidMint.brand}
            flexDirection="column"
          >
            <For each={visibleItems()}>
              {(item, index) => {
                const absolute = () => active().window.start + index()
                const isSelected = () => absolute() === active().selected
                return (
                  <box
                    width="100%"
                    backgroundColor={isSelected() ? solidMint.inputFocusBg : solidMint.panelBg}
                    paddingLeft={1}
                  >
                    <text fg={isSelected() ? solidMint.brand : solidMint.body}>
                      {`${isSelected() ? "▸" : " "} ${item.name}  ${item.description}`}
                    </text>
                  </box>
                )
              }}
            </For>
            <text fg={solidMint.muted}>{active().footer}</text>
          </box>
        )}
      </Show>
      <box
        width="100%"
        flexShrink={0}
        border
        borderColor={solidMint.panelBorder}
        backgroundColor={solidMint.panelBg}
        paddingLeft={1}
        paddingRight={1}
        paddingTop={0}
        paddingBottom={0}
        title=" Compose "
        titleColor={solidMint.brand}
      >
        <textarea
          ref={(next: TextareaRenderable) => {
            area = next
          }}
          width="100%"
          minHeight={1}
          maxHeight={composerMaxHeight}
          height={composerHeightForText(draft())}
          wrapMode="none"
          focused={props.focused ?? true}
          placeholder={
            props.placeholder ?? "Message Veasel…  ·  / commands  ·  @ paths  ·  $ skills"
          }
          placeholderColor={solidMint.muted}
          textColor={solidMint.inputText}
          focusedTextColor={solidMint.inputText}
          backgroundColor={solidMint.inputBg}
          focusedBackgroundColor={solidMint.inputFocusBg}
          cursorColor={solidMint.cursor}
          keyBindings={composerKeyBindings}
          onContentChange={() => {
            const next = area?.plainText ?? ""
            setDraft(next)
            props.onDraftChange?.(next)
            if (area) area.height = composerHeightForText(next)
            const prior = dismissed()
            if (prior && prior.value !== next) setDismissed(undefined)
            setSelected(0)
          }}
          onSubmit={submit}
        />
      </box>
    </box>
  )
}

function isAlreadyCompleted(
  menu: ComposerAutocompleteMenu,
  value: string,
  cursor: number,
): boolean {
  const item = menu.items[menu.selected]
  if (!item) return false
  if (menu.kind === "slash") {
    return value.trim() === completeSlashCommand({
      name: item.name,
      insert: item.insert,
      usage: item.usage,
    }).trim()
  }
  if (menu.kind === "path") {
    const mention = pathMentionAt(value, cursor)
    return Boolean(mention && mention.query === item.name.replace(/^@/, ""))
  }
  const mention = skillMentionAt(value, cursor)
  return Boolean(mention && mention.query === item.name.replace(/^\$/, ""))
}
