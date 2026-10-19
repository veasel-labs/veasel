import { describe, expect, test } from "bun:test"
import {
  attentionMessageForStatus,
  createAttentionNotifier,
  shouldNotifyAttention,
  type AttentionRendererLike,
} from "./attention"

function fakeRenderer() {
  const listeners = new Map<string, Array<() => void>>()
  const sent: Array<{ message: string; title?: string }> = []
  const renderer: AttentionRendererLike = {
    on(event, listener) {
      listeners.set(event, [...(listeners.get(event) ?? []), listener])
    },
    off(event, listener) {
      listeners.set(event, (listeners.get(event) ?? []).filter((item) => item !== listener))
    },
    triggerNotification(message, title) {
      sent.push({ message, title })
      return true
    },
  }
  const emit = (event: "focus" | "blur") => {
    for (const listener of listeners.get(event) ?? []) listener()
  }
  return { renderer, sent, emit, listeners }
}

describe("attention notifications", () => {
  test("only blurred terminals notify", () => {
    expect(shouldNotifyAttention("blurred")).toBe(true)
    expect(shouldNotifyAttention("focused")).toBe(false)
    expect(shouldNotifyAttention("unknown")).toBe(false)
  })

  test("messages cover completed and failed turns only", () => {
    expect(attentionMessageForStatus("completed", "Fix bug")).toBe("Turn complete · Fix bug")
    expect(attentionMessageForStatus("failed")).toBe("Turn failed")
    expect(attentionMessageForStatus("cancelled")).toBeUndefined()
    expect(attentionMessageForStatus("uncertain")).toBeUndefined()
  })

  test("notifies after blur, stays quiet after focus, disposes listeners", () => {
    const fake = fakeRenderer()
    const notifier = createAttentionNotifier(fake.renderer)
    expect(notifier.notifyTurnFinished("completed", "Chat")).toBe(false)
    fake.emit("blur")
    expect(notifier.focusState()).toBe("blurred")
    expect(notifier.notifyTurnFinished("completed", "Chat")).toBe(true)
    expect(fake.sent).toEqual([{ message: "Turn complete · Chat", title: "Veasel Code" }])
    fake.emit("focus")
    expect(notifier.notifyTurnFinished("failed", "Chat")).toBe(false)
    notifier.dispose()
    fake.emit("blur")
    expect(notifier.notifyTurnFinished("completed", "Chat")).toBe(false)
    expect(fake.sent.length).toBe(1)
  })

  test("control bytes are stripped from notification text", () => {
    const fake = fakeRenderer()
    const notifier = createAttentionNotifier(fake.renderer)
    fake.emit("blur")
    expect(notifier.notifyTurnFinished("completed", "a\u0007b\u001b[31m")).toBe(true)
    expect(fake.sent[0]?.message).toBe("Turn complete · a b [31m")
  })
})
