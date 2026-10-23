import { expect, test } from "bun:test"
import type { VeaselApiClient } from "../api-client"
import type { DialogHost } from "./ui/dialog"
import type { ToastHost } from "./ui/toast"
import { createLiveMcpWorkflows, openLiveMcpDialog } from "./live-mcp-dialog"

test("ignores an MCP inventory response after the workspace changes", async () => {
  let openedDialog = false
  const focused: boolean[] = []
  let currentContext = true
  let resolveConfigured!: (value: { servers: never[] }) => void
  let resolveTrusted!: (value: never[]) => void
  const api = {
    listConfiguredMcpServers: () => new Promise<{ servers: never[] }>((resolve) => { resolveConfigured = resolve }),
    listSessionMcpServers: () => new Promise<never[]>((resolve) => { resolveTrusted = resolve }),
  } as unknown as VeaselApiClient
  const dialog = {
    replace: () => { openedDialog = true },
    push: () => { openedDialog = true },
    clear: () => {},
    pop: () => {},
    open: () => false,
    stack: () => [],
  } as unknown as DialogHost

  const pending = openLiveMcpDialog({
    api,
    dialog,
    toast: { info: () => {}, success: () => {}, warning: () => {}, error: () => {} } as unknown as ToastHost,
    directory: "/workspace/old",
    sessionId: "old-session",
    setComposerFocused: (value) => focused.push(value),
    runTrustAction: () => {},
    runConfigure: () => {},
    isCurrentContext: () => currentContext,
  })
  currentContext = false
  resolveConfigured({ servers: [] })
  resolveTrusted([])
  await pending

  expect(openedDialog).toBe(false)
  expect(focused).toEqual([false, true])
})

test("MCP actions from an open dialog stay bound to its original session and workspace", async () => {
  const calls: Array<{ kind: string; sessionId?: string; directory?: string }> = []
  const api = {
    updateConfiguredMcpServer: async (_name: string, input: { directory?: string }) => {
      calls.push({ kind: "configure", directory: input.directory })
    },
    setSessionMcpServerTrust: async (sessionId: string) => {
      calls.push({ kind: "trust", sessionId })
    },
  } as unknown as VeaselApiClient
  const workflows = createLiveMcpWorkflows({
    api,
    dialog: {} as DialogHost,
    toast: { info: () => {}, success: () => {}, warning: () => {}, error: () => {} } as unknown as ToastHost,
    directory: () => "/workspace/new",
    sessionId: () => "new-session",
    setComposerFocused: () => {},
  })

  await workflows.runConfigure("enable", "project", "demo", {
    directory: "/workspace/old",
    sessionId: "old-session",
  })
  await workflows.runTrustAction(true, "configured/demo", {
    directory: "/workspace/old",
    sessionId: "old-session",
  })

  expect(calls).toEqual([
    { kind: "configure", directory: "/workspace/old" },
    { kind: "trust", sessionId: "old-session" },
  ])
})
