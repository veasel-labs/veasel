/** @jsxImportSource @opentui/solid */
import { createSignal } from "solid-js"
import type { TextareaRenderable } from "@opentui/core"
import {
  composerHeightForText,
  composerKeyBindings,
  composerMaxHeight,
} from "../composer-input"
import { solidMint } from "./theme"

export type SolidComposerProps = {
  placeholder?: string
  focused?: boolean
  onSubmit?: (text: string) => void
}

// Reactive multiline composer. Key bindings and height policy stay in the
// shared pure helpers used by the imperative ComposerRenderable.
export function SolidComposer(props: SolidComposerProps) {
  const [draft, setDraft] = createSignal("")
  let area: TextareaRenderable | undefined

  const submit = () => {
    const text = (area?.plainText ?? draft()).trimEnd()
    if (text.length === 0) return
    props.onSubmit?.(text)
    area?.setText("")
    setDraft("")
    if (area) area.height = composerHeightForText("")
  }

  return (
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
        placeholder={props.placeholder ?? "Message Veasel… (Enter to send)"}
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
        }}
        onSubmit={submit}
      />
    </box>
  )
}
