/** @jsxImportSource @opentui/solid */
import {
  createContext,
  createSignal,
  onCleanup,
  Show,
  useContext,
  type JSX,
  type ParentProps,
} from "solid-js"
import { useKeyboard, useRenderer, useTerminalDimensions } from "@opentui/solid"
import type { KeyEvent, Renderable } from "@opentui/core"
import { useSolidTheme } from "../theme"

export type DialogSize = "medium" | "large"

export type DialogEntry = {
  element: () => JSX.Element
  onClose?: () => void
  size?: DialogSize
}

export type DialogReplaceOptions = {
  onClose?: () => void
  size?: DialogSize
}

export type DialogHost = {
  readonly open: () => boolean
  readonly stack: () => DialogEntry[]
  replace: (element: () => JSX.Element, options?: DialogReplaceOptions | (() => void)) => void
  /** Stack a dialog above the current one (Esc / pop returns to the previous). */
  push: (element: () => JSX.Element, options?: DialogReplaceOptions) => void
  clear: () => void
  pop: () => void
}

const DialogContext = createContext<DialogHost>()

export function dialogWidth(size: DialogSize = "medium"): number {
  return size === "large" ? 72 : 56
}

export function DialogProvider(props: ParentProps) {
  const renderer = useRenderer()
  const [stack, setStack] = createSignal<DialogEntry[]>([])
  let previousFocus: Renderable | null = null

  const restoreFocus = () => {
    const target = previousFocus
    previousFocus = null
    if (!target || target.isDestroyed) return
    queueMicrotask(() => {
      if (!target.isDestroyed) target.focus()
    })
  }

  const host: DialogHost = {
    open: () => stack().length > 0,
    stack,
    replace(element, options) {
      const normalized: DialogReplaceOptions =
        typeof options === "function" ? { onClose: options } : (options ?? {})
      if (stack().length === 0) {
        previousFocus = renderer.currentFocusedRenderable
        previousFocus?.blur()
      }
      for (const entry of stack()) entry.onClose?.()
      setStack([{ element, onClose: normalized.onClose, size: normalized.size }])
    },
    push(element, options = {}) {
      if (stack().length === 0) {
        previousFocus = renderer.currentFocusedRenderable
        previousFocus?.blur()
      }
      setStack((current) => [
        ...current,
        { element, onClose: options.onClose, size: options.size },
      ])
    },
    clear() {
      for (const entry of stack()) entry.onClose?.()
      setStack([])
      restoreFocus()
    },
    pop() {
      const current = stack()
      if (current.length === 0) return
      current.at(-1)?.onClose?.()
      const next = current.slice(0, -1)
      setStack(next)
      if (next.length === 0) restoreFocus()
    },
  }

  useKeyboard((key: KeyEvent) => {
    if (stack().length === 0) return
    if (key.name === "escape") {
      key.preventDefault()
      host.pop()
    }
  })

  return (
    <DialogContext.Provider value={host}>
      {props.children}
      <Show when={stack().length > 0}>
        <DialogBackdrop
          size={stack().at(-1)?.size ?? "medium"}
          onDismiss={() => host.clear()}
        >
          <Show when={stack().at(-1)} keyed>
            {(entry) => entry.element()}
          </Show>
        </DialogBackdrop>
      </Show>
    </DialogContext.Provider>
  )
}

export function useDialog(): DialogHost {
  const value = useContext(DialogContext)
  if (!value) throw new Error("useDialog must be used within DialogProvider")
  return value
}

function DialogBackdrop(props: ParentProps<{ onDismiss: () => void; size?: DialogSize }>) {
  const colors = useSolidTheme()
  const dimensions = useTerminalDimensions()
  const size = () => props.size ?? "medium"
  const width = () =>
    Math.min(dialogWidth(size()), Math.max(40, dimensions().width - 4))
  return (
    <box
      position="absolute"
      left={0}
      top={0}
      zIndex={3000}
      width={dimensions().width}
      height={dimensions().height}
      alignItems="center"
      justifyContent="center"
      backgroundColor={colors.shellBg}
      onMouseUp={() => props.onDismiss()}
    >
      <box
        onMouseUp={(event: { stopPropagation(): void }) => event.stopPropagation()}
        width={width()}
        maxHeight={Math.max(12, dimensions().height - 4)}
        flexDirection="column"
        backgroundColor={colors.panelBg}
        border
        borderColor={colors.headerBorder}
        paddingTop={1}
        paddingBottom={1}
        paddingLeft={2}
        paddingRight={2}
      >
        {props.children}
      </box>
    </box>
  )
}

export function DialogHeader(props: { title: string; hint?: string }) {
  const colors = useSolidTheme()
  return (
    <box
      width="100%"
      flexDirection="row"
      justifyContent="space-between"
      flexShrink={0}
      marginBottom={1}
    >
      <text fg={colors.headerTitle}>
        <strong>{props.title}</strong>
      </text>
      <text fg={colors.muted}>{props.hint ?? "Esc"}</text>
    </box>
  )
}

/** Shared header / body / footer chrome used by alert, confirm, prompt, and help. */
export function DialogLayout(
  props: ParentProps<{
    header: JSX.Element
    footer?: JSX.Element
  }>,
) {
  return (
    <box width="100%" flexDirection="column" gap={1} paddingBottom={1}>
      {props.header}
      <box width="100%" flexGrow={1} flexShrink={1}>
        {props.children}
      </box>
      {props.footer}
    </box>
  )
}
