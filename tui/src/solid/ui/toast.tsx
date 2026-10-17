/** @jsxImportSource @opentui/solid */
import {
  createContext,
  createSignal,
  onCleanup,
  Show,
  useContext,
  type ParentProps,
} from "solid-js"
import { useRenderer, useTerminalDimensions } from "@opentui/solid"
import { useSolidTheme } from "../theme"
import { themes, type Theme } from "../../themes"

export type ToastVariant = "info" | "success" | "warning" | "error"

export type ToastAction = {
  label: string
  run: () => void
}

export type ToastOptions = {
  title?: string
  message: string
  variant: ToastVariant
  duration: number
  action?: ToastAction
}

export type ToastInput = Omit<ToastOptions, "duration"> & { duration?: number }

export const defaultToastDurationMs = 5000

/** Semantic border color per variant — aligns with status tokens in themes.ts. */
export function toastBorderColor(variant: ToastVariant, colors: Theme = themes.mint): string {
  switch (variant) {
    case "success":
      return colors.statusOk
    case "warning":
      return colors.statusWarn
    case "error":
      return colors.statusError
    case "info":
    default:
      return colors.brand
  }
}

export function toastVariantLabel(variant: ToastVariant): string {
  switch (variant) {
    case "success":
      return "ok"
    case "warning":
      return "warn"
    case "error":
      return "error"
    case "info":
    default:
      return "info"
  }
}

export type ToastHost = {
  show: (options: ToastInput) => void
  info: (message: string, title?: string) => void
  success: (message: string, title?: string) => void
  warning: (message: string, title?: string) => void
  error: (message: string, title?: string) => void
  dismiss: () => void
  pause: () => void
  resume: () => void
  activate: () => void
  readonly current: () => ToastOptions | null
  readonly pending: () => number
}

const ToastContext = createContext<ToastHost>()

function createToastHost(): ToastHost {
  const [current, setCurrent] = createSignal<ToastOptions | null>(null)
  const [queue, setQueue] = createSignal<ToastOptions[]>([])
  let timeoutHandle: ReturnType<typeof setTimeout> | null = null
  let startedAt = 0
  let remaining = 0
  let paused = false

  const clearTimer = () => {
    if (!timeoutHandle) return
    clearTimeout(timeoutHandle)
    timeoutHandle = null
  }

  const start = (duration: number) => {
    clearTimer()
    remaining = duration
    startedAt = Date.now()
    timeoutHandle = setTimeout(() => dismiss(), duration)
    // Bun/Node: do not keep the process alive for toast timers alone.
    timeoutHandle.unref?.()
  }

  const dismiss = () => {
    clearTimer()
    const next = queue()[0]
    setQueue((items) => items.slice(1))
    setCurrent(next ?? null)
    if (!next) {
      paused = false
      return
    }
    remaining = next.duration
    if (!paused) start(next.duration)
  }

  const show = (options: ToastInput) => {
    const toastOptions: ToastOptions = {
      ...options,
      duration: options.duration ?? defaultToastDurationMs,
    }
    if (current() && (paused || queue().length > 0)) {
      setQueue((items) => [...items, toastOptions])
      return
    }
    setCurrent(toastOptions)
    start(toastOptions.duration)
  }

  const host: ToastHost = {
    show,
    info: (message, title) => show({ variant: "info", message, title }),
    success: (message, title) => show({ variant: "success", message, title }),
    warning: (message, title) => show({ variant: "warning", message, title }),
    error: (message, title) => show({ variant: "error", message, title }),
    dismiss,
    pause() {
      if (!current() || paused) return
      paused = true
      remaining = Math.max(0, remaining - (Date.now() - startedAt))
      clearTimer()
    },
    resume() {
      if (!current() || !paused) return
      paused = false
      start(remaining)
    },
    activate() {
      const action = current()?.action
      dismiss()
      action?.run()
    },
    current,
    pending: () => queue().length,
  }

  onCleanup(clearTimer)
  return host
}

export function ToastProvider(props: ParentProps) {
  const host = createToastHost()
  return (
    <ToastContext.Provider value={host}>
      {props.children}
      <ToastOverlay />
    </ToastContext.Provider>
  )
}

export function useToast(): ToastHost {
  const value = useContext(ToastContext)
  if (!value) throw new Error("useToast must be used within ToastProvider")
  return value
}

function ToastOverlay() {
  const colors = useSolidTheme()
  const toast = useToast()
  const dimensions = useTerminalDimensions()
  const renderer = useRenderer()
  const [hovered, setHovered] = createSignal(false)

  return (
    <Show when={toast.current()}>
      {(current) => (
        <box
          position="absolute"
          top={1}
          right={2}
          zIndex={2500}
          maxWidth={Math.min(56, Math.max(24, dimensions().width - 6))}
          flexDirection="column"
          border
          borderColor={toastBorderColor(current().variant, colors)}
          backgroundColor={colors.panelBg}
          paddingTop={1}
          paddingBottom={1}
          paddingLeft={2}
          paddingRight={2}
          onMouseOver={() => {
            setHovered(true)
            toast.pause()
          }}
          onMouseOut={() => {
            setHovered(false)
            toast.resume()
          }}
          onMouseUp={() => {
            if (renderer.getSelection()?.getSelectedText()) return
            toast.activate()
          }}
        >
          <box width="100%" flexDirection="row" marginBottom={current().title ? 1 : 0}>
            <Show
              when={current().title}
              fallback={
                <text fg={colors.muted} flexShrink={0}>
                  {toastVariantLabel(current().variant)} ·{" "}
                </text>
              }
            >
              <text fg={colors.headerTitle} flexGrow={1}>
                <strong>{current().title}</strong>
              </text>
            </Show>
            <box flexGrow={1} />
            <text fg={hovered() ? colors.brand : colors.muted} flexShrink={0}>
              {current().action ? `› ${current().action!.label}` : "dismiss"}
            </text>
          </box>
          <text fg={colors.body} wrapMode="word">
            {current().message}
          </text>
          <Show when={toast.pending() > 0}>
            <text fg={colors.muted} marginTop={1}>
              +{toast.pending()} more
            </text>
          </Show>
        </box>
      )}
    </Show>
  )
}
