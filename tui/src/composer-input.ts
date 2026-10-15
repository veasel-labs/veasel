// Multiline session composer: Enter submits; Shift+Enter / Ctrl+J / Alt+Enter /
// Ctrl+Enter insert a newline (Claude Code / OpenCode / Codex table-stakes).
// Built on OpenTUI Textarea so Input's single-line newline strip does not fight
// chat-style drafts.

import {
  TextareaRenderable,
  type KeyBinding,
  type RenderContext,
  type TextareaOptions,
} from "@opentui/core"

export const composerMaxHeight = 6

export const composerKeyBindings: KeyBinding[] = [
  { name: "return", action: "submit" },
  { name: "kpenter", action: "submit" },
  // Classic Ctrl+J is a raw linefeed (\n); keep it as newline, not submit.
  { name: "linefeed", action: "newline" },
  { name: "j", ctrl: true, action: "newline" },
  { name: "return", shift: true, action: "newline" },
  { name: "kpenter", shift: true, action: "newline" },
  { name: "return", ctrl: true, action: "newline" },
  { name: "kpenter", ctrl: true, action: "newline" },
  // Alt+Enter for terminals that do not encode Shift+Enter.
  { name: "return", meta: true, action: "newline" },
  { name: "kpenter", meta: true, action: "newline" },
]

export function composerHeightForText(text: string, maxHeight = composerMaxHeight): number {
  const lines = text.length === 0 ? 1 : text.split("\n").length
  return Math.min(maxHeight, Math.max(1, lines))
}

export type ComposerOptions = Omit<TextareaOptions, "keyBindings"> & {
  maxLength?: number
}

export class ComposerRenderable extends TextareaRenderable {
  private _maxLength: number

  constructor(ctx: RenderContext, options: ComposerOptions = {}) {
    const maxLength = options.maxLength ?? 1_048_576
    const initial = (options.initialValue ?? "").slice(0, maxLength)
    const userListener = options.onContentChange
    super(ctx, {
      ...options,
      initialValue: initial,
      height: composerHeightForText(initial),
      minHeight: 1,
      maxHeight: composerMaxHeight,
      wrapMode: options.wrapMode ?? "none",
      keyBindings: composerKeyBindings,
      onContentChange: undefined,
    })
    this._maxLength = maxLength
    this.onContentChange = userListener
  }

  syncHeight(): void {
    const next = composerHeightForText(this.plainText)
    if (this.height !== next) this.height = next
  }

  get value(): string {
    return this.plainText
  }

  set value(value: string) {
    const next = value.slice(0, this._maxLength)
    if (this.plainText === next) return
    this.setText(next)
    this.cursorOffset = next.length
    this.syncHeight()
  }

  override insertText(text: string): void {
    const remaining = this._maxLength - this.plainText.length
    if (remaining <= 0) return
    super.insertText(text.slice(0, remaining))
    this.syncHeight()
  }

  override set onContentChange(handler: TextareaOptions["onContentChange"]) {
    super.onContentChange = () => {
      this.syncHeight()
      handler?.({})
    }
  }

  override get onContentChange(): TextareaOptions["onContentChange"] {
    return super.onContentChange
  }
}
