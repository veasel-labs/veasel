/** @jsxImportSource @opentui/solid */
import { For, Show, createEffect, createMemo, createSignal } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { KeyEvent, PasteEvent, TextareaRenderable } from "@opentui/core"
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
import { useSolidTheme } from "./theme"
import {
  acceptComposerAutocomplete,
  jumpComposerAutocomplete,
  moveComposerAutocomplete,
  resolveComposerAutocomplete,
  windowedComposerItems,
  type ComposerAutocompleteDismissed,
  type ComposerAutocompleteMenu,
} from "./composer-autocomplete"
import {
  attachmentChipLabel,
  formatMessageWithAttachments,
  normalizeAttachmentPath,
  resolveAttachmentPath,
  type ComposerAttachment,
} from "./composer-attachments"
import { resolveLiveSlash } from "./live-slash"
import {
  applyComposerReadlineKey,
  emptyComposerReadlineState,
  rememberReadlineSubmit,
  type ComposerReadlineState,
} from "./composer-readline"
import { sharedPathFrecencyStore } from "../path-frecency"

export type SolidComposerProps = {
  placeholder?: string
  focused?: boolean
  onSubmit?: (text: string) => void
  workspaceRoot?: string
  skills?: SkillCatalogEntry[]
  skillCatalogStatus?: string
  slashContext?: SlashCompletionContext
  listPaths?: (root: string) => string[]
  /** When this token changes, replace the composer draft (stash restore). */
  restoreToken?: { id: string; text: string }
  /** Latest draft text for stash / external observers. */
  onDraftChange?: (text: string) => void
  /** Staged local files / images (paths; text API mentions on submit). */
  attachments?: ComposerAttachment[]
  onRemoveAttachment?: (id: string) => void
  onPreviewAttachment?: (attachment: ComposerAttachment) => void
  /** When paste is a local filepath, stage it instead of inserting text. */
  onPathPaste?: (path: string) => boolean | void
}

function kindTitle(kind: ComposerAutocompleteMenu["kind"]): string {
  if (kind === "path") return "paths"
  if (kind === "skill") return "skills"
  return "commands"
}

// Reactive multiline composer with `/` `@` `$` autocomplete (classic matchers).
export function SolidComposer(props: SolidComposerProps) {
  const colors = useSolidTheme()
  const [draft, setDraft] = createSignal("")
  const [selected, setSelected] = createSignal(0)
  const [dismissed, setDismissed] = createSignal<ComposerAutocompleteDismissed | undefined>(undefined)
  const [readline, setReadline] = createSignal<ComposerReadlineState>(emptyComposerReadlineState())
  let area: TextareaRenderable | undefined
  let lastRestoreId: string | undefined
  /** Token waiting for the textarea mount (home `/` race). */
  let pendingRestore: { id: string; text: string } | undefined

  const skills = () => props.skills ?? []
  const pathFrecency = sharedPathFrecencyStore()

  const applyRestore = (token: { id: string; text: string }) => {
    lastRestoreId = token.id
    pendingRestore = undefined
    setDraft(token.text)
    setDismissed(undefined)
    setSelected(0)
    if (area) {
      area.setText(token.text)
      area.height = composerHeightForText(token.text)
      area.cursorOffset = token.text.length
    } else {
      pendingRestore = token
    }
    props.onDraftChange?.(token.text)
  }

  createEffect(() => {
    const token = props.restoreToken
    if (!token || token.id === lastRestoreId) return
    applyRestore(token)
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
      pathFrecency,
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
    props.onDraftChange?.("")
    setSelected(0)
    setDismissed(undefined)
    if (area) area.height = composerHeightForText("")
  }

  const attachments = () => props.attachments ?? []

  const send = (text: string) => {
    const payload = formatMessageWithAttachments(text, attachments())
    if (!payload.trim()) return
    setReadline((current) => rememberReadlineSubmit(current, payload))
    props.onSubmit?.(payload)
    clearComposer()
  }

  const accept = (mode: "tab" | "enter"): boolean => {
    const value = area?.plainText ?? draft()
    const cursor = area?.cursorOffset ?? value.length
    const active = menu()
    if (!active) return false
    // Prefer an already-typed runnable LiveApp slash over a fuzzy description
    // hit (e.g. `/status` must not become `/patches` via "filter by … status").
    if (mode === "enter" && active.kind === "slash") {
      const trimmed = value.trimEnd()
      const action = resolveLiveSlash(trimmed)
      if (
        action.kind !== "passthrough"
        && action.kind !== "unknown"
        && action.kind !== "unsupported"
      ) {
        send(trimmed)
        return true
      }
    }
    const result = acceptComposerAutocomplete({
      value,
      cursor,
      skills: skills(),
      slashContext: props.slashContext,
      workspaceRoot: props.workspaceRoot,
      listPaths: props.listPaths,
      pathFrecency,
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

  const handlePaste = (event: PasteEvent) => {
    if (!props.onPathPaste) return
    const text = new TextDecoder().decode(event.bytes).replace(/[\x00-\x1f\x7f-\x9f]/g, "")
    // Only intercept paste when the clipboard looks like a single local path.
    if (!normalizeAttachmentPath(text)) return
    const resolved = resolveAttachmentPath(text, { cwd: props.workspaceRoot })
    if (!resolved) return
    props.onPathPaste(resolved)
    event.preventDefault()
    event.stopPropagation()
  }

  useKeyboard((key: KeyEvent) => {
    if (!(props.focused ?? true)) return
    const active = menu()

    const consume = () => {
      key.preventDefault()
      key.stopPropagation()
    }

    if (active) {
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
      return
    }

    // Autocomplete closed → classic readline / ↑↓ prompt history.
    const value = area?.plainText ?? draft()
    const cursor = area?.cursorOffset ?? value.length
    const result = applyComposerReadlineKey(
      { ...readline(), value, cursor },
      {
        name: key.name,
        ctrl: key.ctrl,
        meta: key.meta,
        shift: key.shift,
        sequence: key.sequence,
      },
    )
    if (result.kind === "ignore") return
    consume()
    setReadline(result.state)
    applyEdit(result.state.value, result.state.cursor)
    props.onDraftChange?.(result.state.value)
  })

  return (
    <box width="100%" flexShrink={0} flexDirection="column" gap={0}>
      <Show when={(props.focused ?? true) && props.skillCatalogStatus && skillMentionAt(draft(), area?.cursorOffset ?? draft().length)}>
        <text fg={solidMint.muted}>{props.skillCatalogStatus}</text>
      </Show>
      <Show when={menu()}>
        {(active) => (
          <box
            width="100%"
            border
            borderColor={colors.panelBorder}
            backgroundColor={colors.panelBg}
            paddingLeft={1}
            paddingRight={1}
            paddingTop={0}
            paddingBottom={0}
            title={` ${kindTitle(active().kind)} `}
            titleColor={colors.brand}
            flexDirection="column"
          >
            <For each={visibleItems()}>
              {(item, index) => {
                const absolute = () => active().window.start + index()
                const isSelected = () => absolute() === active().selected
                return (
                  <box
                    width="100%"
                    backgroundColor={isSelected() ? colors.inputFocusBg : colors.panelBg}
                    paddingLeft={1}
                  >
                    <text fg={isSelected() ? colors.brand : colors.body}>
                      {`${isSelected() ? "▸" : " "} ${item.name}  ${item.description}`}
                    </text>
                  </box>
                )
              }}
            </For>
            <text fg={colors.muted}>{active().footer}</text>
          </box>
        )}
      </Show>
      <Show when={attachments().length > 0}>
        <box
          width="100%"
          flexShrink={0}
          flexDirection="column"
          backgroundColor={colors.panelBg}
          border
          borderColor={colors.panelBorder}
          paddingLeft={1}
          paddingRight={1}
          title=" Attachments "
          titleColor={colors.brand}
        >
          <For each={attachments()}>
            {(item) => (
              <box flexDirection="row" width="100%" gap={1}>
                <box
                  onMouseUp={() => props.onPreviewAttachment?.(item)}
                  flexGrow={1}
                >
                  <text wrapMode="none">
                    <span style={{ fg: colors.body }}>{attachmentChipLabel(item)}</span>
                  </text>
                </box>
                <box onMouseUp={() => props.onRemoveAttachment?.(item.id)}>
                  <text wrapMode="none">
                    <span style={{ fg: colors.muted }}>✕</span>
                  </text>
                </box>
              </box>
            )}
          </For>
          <text wrapMode="none">
            <span style={{ fg: colors.muted }}>click preview · ✕ remove · submit sends @paths</span>
          </text>
        </box>
      </Show>
      <box
        width="100%"
        flexShrink={0}
        border
        borderColor={colors.panelBorder}
        backgroundColor={colors.panelBg}
        paddingLeft={1}
        paddingRight={1}
        paddingTop={0}
        paddingBottom={0}
        title=" Compose "
        titleColor={colors.brand}
      >
        <textarea
          ref={(next: TextareaRenderable) => {
            area = next
            // Home `/` opens the composer and sets restoreToken before the
            // textarea exists; flush so `/connect` is not submitted as `connect`.
            if (next && pendingRestore) {
              const token = pendingRestore
              pendingRestore = undefined
              next.setText(token.text)
              next.height = composerHeightForText(token.text)
              next.cursorOffset = token.text.length
              setDraft(token.text)
              props.onDraftChange?.(token.text)
            }
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
          placeholderColor={colors.muted}
          textColor={colors.inputText}
          focusedTextColor={colors.inputText}
          backgroundColor={colors.inputBg}
          focusedBackgroundColor={colors.inputFocusBg}
          cursorColor={colors.cursor}
          keyBindings={composerKeyBindings}
          onPaste={handlePaste}
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
