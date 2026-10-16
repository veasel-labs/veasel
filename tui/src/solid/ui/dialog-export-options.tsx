/** @jsxImportSource @opentui/solid */
import { For, Show, createSignal } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { KeyEvent } from "@opentui/core"
import { DialogHeader, DialogLayout, useDialog } from "./dialog"
import { solidMint } from "../theme"

export type ExportFormat = "markdown" | "json"

export type ExportOptionsResult = {
  action: "copy" | "export"
  format: ExportFormat
  thinking: boolean
  tools: boolean
  sanitize: boolean
}

export type DialogExportOptionsProps = {
  defaultThinking?: boolean
  onConfirm?: (options: ExportOptionsResult) => void
  onCancel?: () => void
}

type Active = ExportFormat | "thinking" | "tools" | "sanitize" | "copy" | "export"

function orderFor(format: ExportFormat): Active[] {
  return format === "markdown"
    ? ["markdown", "json", "thinking", "tools", "copy", "export"]
    : ["markdown", "json", "sanitize", "copy", "export"]
}

export function DialogExportOptions(props: DialogExportOptionsProps) {
  const dialog = useDialog()
  const [format, setFormat] = createSignal<ExportFormat>("markdown")
  const [thinking, setThinking] = createSignal(props.defaultThinking ?? true)
  const [tools, setTools] = createSignal(true)
  const [sanitize, setSanitize] = createSignal(false)
  const [active, setActive] = createSignal<Active>("markdown")

  const confirm = (action: "copy" | "export") => {
    // Do not clear here: export may immediately replace with the result dialog.
    props.onConfirm?.({
      action,
      format: format(),
      thinking: thinking(),
      tools: tools(),
      sanitize: sanitize(),
    })
  }

  const activate = () => {
    const current = active()
    if (current === "markdown" || current === "json") {
      setFormat(current)
      return
    }
    if (current === "thinking") {
      setThinking((value) => !value)
      return
    }
    if (current === "tools") {
      setTools((value) => !value)
      return
    }
    if (current === "sanitize") {
      setSanitize((value) => !value)
      return
    }
    if (current === "copy" || current === "export") confirm(current)
  }

  useKeyboard((key: KeyEvent) => {
    if (key.name === "tab") {
      key.preventDefault()
      const order = orderFor(format())
      const index = order.indexOf(active())
      const next = order[(index < 0 ? 0 : index + 1) % order.length]
      setActive(next)
      return
    }
    // Chord shortcuts for reliable testRender / when Tab focus is awkward.
    if (!key.ctrl && !key.meta && key.name === "x") {
      key.preventDefault()
      confirm("export")
      return
    }
    if (!key.ctrl && !key.meta && key.name === "c") {
      key.preventDefault()
      confirm("copy")
      return
    }
    if (key.name === "return" || key.name === "kpenter") {
      key.preventDefault()
      activate()
    }
  })

  const optionBg = (id: Active, selected: boolean) => {
    if (active() === id) return solidMint.inputFocusBg
    if (selected) return solidMint.panelBg
    return undefined
  }

  const optionFg = (id: Active, selected: boolean) => {
    if (active() === id) return solidMint.brand
    if (selected) return solidMint.body
    return solidMint.muted
  }

  return (
    <DialogLayout
      header={<DialogHeader title="Export session" hint="Tab · x export · c copy · Esc" />}
      footer={
        <box flexDirection="row" justifyContent="flex-end" gap={1}>
          <box
            paddingLeft={2}
            paddingRight={2}
            backgroundColor={optionBg("copy", false)}
            onMouseUp={() => confirm("copy")}
          >
            <text fg={optionFg("copy", false)}>Copy</text>
          </box>
          <box
            paddingLeft={2}
            paddingRight={2}
            backgroundColor={
              active() === "export" ? solidMint.inputFocusBg : solidMint.brand
            }
            onMouseUp={() => confirm("export")}
          >
            <text fg={active() === "export" ? solidMint.brand : solidMint.shellBg}>Export</text>
          </box>
        </box>
      }
    >
      <box flexDirection="column" gap={1}>
        <box flexDirection="row" gap={1}>
          <text fg={solidMint.body}>Export as:</text>
          <For each={["markdown", "json"] as const}>
            {(item) => (
              <box
                paddingLeft={1}
                paddingRight={1}
                backgroundColor={optionBg(item, format() === item)}
                onMouseUp={() => {
                  setFormat(item)
                  setActive(item)
                }}
              >
                <text fg={optionFg(item, format() === item)}>
                  {format() === item ? "◉" : "○"} {item === "markdown" ? "Markdown" : "JSON"}
                </text>
              </box>
            )}
          </For>
        </box>
        <Show when={format() === "markdown"}>
          <box
            flexDirection="row"
            gap={1}
            backgroundColor={optionBg("thinking", thinking())}
            onMouseUp={() => {
              setActive("thinking")
              setThinking((value) => !value)
            }}
          >
            <text fg={optionFg("thinking", thinking())}>
              {thinking() ? "[x]" : "[ ]"} Include thinking
            </text>
          </box>
          <box
            flexDirection="row"
            gap={1}
            backgroundColor={optionBg("tools", tools())}
            onMouseUp={() => {
              setActive("tools")
              setTools((value) => !value)
            }}
          >
            <text fg={optionFg("tools", tools())}>
              {tools() ? "[x]" : "[ ]"} Include tools
            </text>
          </box>
        </Show>
        <Show when={format() === "json"}>
          <box
            flexDirection="row"
            gap={1}
            backgroundColor={optionBg("sanitize", sanitize())}
            onMouseUp={() => {
              setActive("sanitize")
              setSanitize((value) => !value)
            }}
          >
            <text fg={optionFg("sanitize", sanitize())}>
              {sanitize() ? "[x]" : "[ ]"} Sanitize sensitive data
            </text>
          </box>
        </Show>
      </box>
    </DialogLayout>
  )
}

export function openDialogExportOptions(
  dialog: ReturnType<typeof useDialog>,
  props: DialogExportOptionsProps = {},
) {
  dialog.replace(
    () => (
      <DialogExportOptions
        defaultThinking={props.defaultThinking}
        onConfirm={props.onConfirm}
        onCancel={props.onCancel}
      />
    ),
    {
      size: "medium",
      onClose: props.onCancel,
    },
  )
}
