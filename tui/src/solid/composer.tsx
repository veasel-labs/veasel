/** @jsxImportSource @opentui/solid */
import { For, Show, createMemo, createSignal } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { KeyEvent, TextareaRenderable } from "@opentui/core"
import {
  composerHeightForText,
  composerKeyBindings,
  composerMaxHeight,
} from "../composer-input"
import type { SkillCatalogEntry } from "../skill-autocomplete"
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

  const skills = () => props.skills ?? demoComposerSkills()

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

  const applyEdit = (value: string, cursor: number) => {
    if (!area) return
    area.setText(value)
    area.cursorOffset = cursor
    setDraft(value)
    area.height = composerHeightForText(value)
    setDismissed(undefined)
    setSelected(0)
  }

  const submit = () => {
    if (menu()) return
    const text = (area?.plainText ?? draft()).trimEnd()
    if (text.length === 0) return
    props.onSubmit?.(text)
    area?.setText("")
    setDraft("")
    setSelected(0)
    setDismissed(undefined)
    if (area) area.height = composerHeightForText("")
  }

  const accept = (mode: "tab" | "enter") => {
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
        setDismissed(undefined)
        const text = value.trimEnd()
        if (text.length === 0) return true
        props.onSubmit?.(text)
        area?.setText("")
        setDraft("")
        setSelected(0)
        if (area) area.height = composerHeightForText("")
        return true
      }
      return false
    }
    if (result.submit && mode === "enter") {
      applyEdit(result.value, result.cursor)
      const text = result.value.trimEnd()
      if (text.length === 0) return true
      props.onSubmit?.(text)
      area?.setText("")
      setDraft("")
      setSelected(0)
      if (area) area.height = composerHeightForText("")
      return true
    }
    applyEdit(result.value, result.cursor)
    return true
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
      const value = area?.plainText ?? draft()
      const cursor = area?.cursorOffset ?? value.length
      const tabbed = acceptComposerAutocomplete({
        value,
        cursor,
        skills: skills(),
        slashContext: props.slashContext,
        workspaceRoot: props.workspaceRoot,
        listPaths: props.listPaths,
        selected: active.selected,
      })
      if (tabbed && tabbed.value.trim() === value.trim() && active.items.length > 1) {
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
