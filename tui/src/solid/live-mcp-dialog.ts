import type { VeaselApiClient } from "../api-client"
import type { DialogHost } from "./ui/dialog"
import type { ToastHost } from "./ui/toast"
import { openDialogAlert } from "./ui/dialog-alert"
import { openDialogSelect } from "./ui/dialog-select"
import { openMcpDialog } from "./component/mcp-dialog"
import { solidMcpServersFromCatalog } from "./mcp-inventory"
import { openDialogConfirm } from "./ui/dialog-confirm"
import { openDialogPrompt } from "./ui/dialog-prompt"
import { resolveLiveSlash, splitMcpArgs } from "./live-slash"

export type McpConfigAction = "remove" | "enable" | "disable"
export type McpConfigScope = "user" | "project"
export type LiveMcpContext = { directory: string; sessionId?: string }

export function createLiveMcpWorkflows(deps: {
  api: VeaselApiClient
  dialog: DialogHost
  toast: ToastHost
  directory: () => string
  sessionId: () => string | undefined
  setComposerFocused: (focused: boolean) => void
}) {
  const { api, dialog, toast, directory, sessionId, setComposerFocused } = deps

  const runTrustAction = async (trusted: boolean, key?: string, context?: LiveMcpContext) => {
    const currentSession = context ? context.sessionId : sessionId()
    if (!currentSession) {
      openDialogAlert(dialog, { title: "Session required", message: "Open a session before trusting an MCP server.", onConfirm: () => setComposerFocused(true) })
      return
    }
    if (!key) {
      openDialogAlert(dialog, {
        title: "MCP server name required",
        message: `Use /mcp ${trusted ? "trust" : "untrust"} <plugin>/<server>. Open /mcp to review available and trusted servers.`,
        onConfirm: () => setComposerFocused(true),
      })
      return
    }
    const separator = key.indexOf("/")
    if (separator <= 0 || separator === key.length - 1) {
      openDialogAlert(dialog, {
        title: "Invalid MCP server name",
        message: "Use the plugin/server key shown by /mcp, for example /mcp trust configured/echo-tools.",
        onConfirm: () => setComposerFocused(true),
      })
      return
    }
    const pluginName = key.slice(0, separator)
    const serverName = key.slice(separator + 1)
    try {
      await api.setSessionMcpServerTrust(currentSession, pluginName, serverName, trusted)
      toast.success(
        trusted
          ? `Trusted ${pluginName}/${serverName}; it connects on the next turn. Each tool call still needs review.`
          : `Revoked trust for ${pluginName}/${serverName}; it will not connect on future turns.`,
        "MCP",
      )
    } catch (error) {
      toast.error(error instanceof Error ? error.message : "Could not update MCP trust", "MCP")
    } finally {
      setComposerFocused(true)
    }
  }

  const runAdd = async (
    input: Extract<ReturnType<typeof resolveLiveSlash>, { kind: "mcp-add" }>,
    context?: LiveMcpContext,
  ) => {
    const root = context ? context.directory : directory()
    const currentSession = context ? context.sessionId : sessionId()
    if (input.scope === "project" && (!currentSession || !root)) {
      openDialogAlert(dialog, { title: "Workspace required", message: "Open a workspace before adding a project-scoped MCP server.", onConfirm: () => setComposerFocused(true) })
      return
    }
    const add = async () => {
      try {
        const server = await api.addConfiguredMcpServer({
          name: input.name, transport: input.transport, command: input.command, args: input.args,
          url: input.url, scope: input.scope, directory: input.scope === "project" ? root : undefined,
        })
        toast.success(`Added configured/${server.name} · ${server.scope ?? input.scope}. Review it, then use /mcp trust configured/${server.name}; tool calls still need approval.`, "MCP")
      } catch (error) {
        openDialogAlert(dialog, { title: "MCP server could not be added", message: error instanceof Error ? error.message : "request failed", onConfirm: () => setComposerFocused(true) })
      } finally {
        setComposerFocused(true)
      }
    }
    try {
      const catalog = await api.listConfiguredMcpServers(root)
      const existing = catalog.servers.find((server) => server.name === input.name && server.scope === input.scope)
      if (existing) {
        openDialogConfirm(dialog, {
          title: "Replace configured MCP server?",
          message: `${input.name} already exists in ${input.scope} scope (${existing.transport}${existing.command ? ` · ${existing.command}` : existing.url_origin ? ` · ${existing.url_origin}` : ""}). Replace its saved configuration?`,
          label: { confirm: "Replace server", cancel: "Keep existing" },
          onClose: () => setComposerFocused(true),
          onConfirm: () => { void add() },
        })
      } else await add()
    } catch (error) {
      openDialogAlert(dialog, { title: "MCP configuration unavailable", message: error instanceof Error ? error.message : "could not check existing servers", onConfirm: () => setComposerFocused(true) })
      setComposerFocused(true)
    }
  }

  const openAddWizard = () => {
    const context: LiveMcpContext = { directory: directory(), sessionId: sessionId() }
    setComposerFocused(false)
    const choices = [
      { title: "User · stdio", value: "user stdio", description: "Local process · available to your user" },
      { title: "User · Streamable HTTP", value: "user http", description: "HTTPS remote or loopback HTTP endpoint" },
      ...(context.sessionId ? [
        { title: "Project · stdio", value: "project stdio", description: "Local process · saved in this workspace" },
        { title: "Project · Streamable HTTP", value: "project http", description: "HTTPS remote or loopback HTTP endpoint · saved in this workspace" },
      ] : []),
    ]
    openDialogSelect(dialog, {
      title: "Add MCP server", options: choices, dismissOnSelect: false,
      onCancel: () => setComposerFocused(true),
      onSelect: (choice) => {
        dialog.clear()
        const [scope, transport] = choice.value.split(" ") as [McpConfigScope, "stdio" | "http"]
        const isStdio = transport === "stdio"
        openDialogPrompt(dialog, {
          title: isStdio ? "Configure stdio MCP" : "Configure Streamable HTTP MCP",
          description: isStdio
            ? "Enter a server name, executable, and optional arguments. Nothing is launched until you trust the server."
            : "Enter a server name and endpoint. Remote servers require HTTPS; HTTP is accepted only for loopback. Nothing connects until trust.",
          placeholder: isStdio ? "name npx -y package-name" : "name https://example.com/mcp",
          confirmLabel: "Validate and add", onCancel: () => setComposerFocused(true),
          onConfirm: (value) => queueMicrotask(() => {
            const parts = splitMcpArgs(value.trim())
            if (parts.length < 2) {
              openDialogAlert(dialog, {
                title: "MCP server details required",
                message: isStdio
                  ? "Enter a server name and executable, for example: docs npx -y @example/docs-mcp."
                  : "Enter a server name and an HTTPS MCP endpoint, for example: docs https://example.com/mcp.",
                onConfirm: () => setComposerFocused(true),
              })
              return
            }
            if (isStdio) {
              void runAdd({ kind: "mcp-add", scope, transport, name: parts[0]!, command: parts[1]!, args: parts.slice(2) }, context)
            } else {
              void runAdd({ kind: "mcp-add", scope, transport: "streamable-http", name: parts[0]!, url: parts[1]! }, context)
            }
          }),
        })
      },
    })
  }

  const runConfigure = async (action: McpConfigAction, scope: McpConfigScope, name: string, context?: LiveMcpContext) => {
    const root = context ? context.directory : directory()
    const currentSession = context ? context.sessionId : sessionId()
    if (scope === "project" && (!currentSession || !root)) {
      openDialogAlert(dialog, { title: "Workspace required", message: "Open the workspace that owns this project-scoped MCP server.", onConfirm: () => setComposerFocused(true) })
      return
    }
    const perform = async () => {
      try {
        if (action === "remove") await api.removeConfiguredMcpServer(name, scope, scope === "project" ? root : undefined)
        else await api.updateConfiguredMcpServer(name, { enabled: action === "enable", scope, directory: scope === "project" ? root : undefined })
        toast.success(`${action === "remove" ? "Removed" : action === "enable" ? "Enabled" : "Disabled"} ${scope}-scope MCP server · ${name}`, "MCP")
      } catch (error) {
        openDialogAlert(dialog, { title: "MCP server update failed", message: error instanceof Error ? error.message : "request failed", onConfirm: () => setComposerFocused(true) })
      } finally {
        setComposerFocused(true)
      }
    }
    if (action === "remove") {
      openDialogConfirm(dialog, {
        title: "Remove configured MCP server?",
        message: `Remove ${name} from ${scope} configuration? This does not remove its executable or remote service.`,
        label: { confirm: "Remove server", cancel: "Keep server" },
        onClose: () => setComposerFocused(true), onConfirm: () => { void perform() },
      })
    } else await perform()
  }

  return { runTrustAction, runAdd, openAddWizard, runConfigure }
}

export async function openLiveMcpDialog(options: {
  api: VeaselApiClient
  dialog: DialogHost
  toast: ToastHost
  directory: string
  sessionId?: string
  setComposerFocused: (focused: boolean) => void
  runTrustAction: (trusted: boolean, key: string, context: LiveMcpContext) => void
  runConfigure: (action: McpConfigAction, scope: McpConfigScope, name: string, context: LiveMcpContext) => void
  isCurrentContext: () => boolean
  filter?: string
}): Promise<void> {
  const { api, dialog, toast, directory, sessionId, setComposerFocused } = options
  const context: LiveMcpContext = { directory, sessionId }
  setComposerFocused(false)
  try {
    const [configured, trusted] = await Promise.all([
      api.listConfiguredMcpServers(directory),
      sessionId ? api.listSessionMcpServers(sessionId) : Promise.resolve([]),
    ])
    if (!options.isCurrentContext()) {
      setComposerFocused(true)
      return
    }
    const needle = options.filter?.trim().toLowerCase() ?? ""
    const servers = solidMcpServersFromCatalog(configured, trusted).filter((server) => {
      if (!needle) return true
      const haystack = `${server.name} ${server.transport} ${server.status} ${server.scope ?? ""}`.toLowerCase()
      return needle.split(/\s+/).every((token) => haystack.includes(token))
    })
    if (servers.length === 0) {
      openDialogAlert(dialog, {
        title: "MCP",
        message: needle
          ? `No MCP servers match “${options.filter?.trim()}”.`
          : "No configured or trusted MCP servers yet. Add with /mcp add [user|project] stdio|http … or configure ~/.config/veasel, then review and /mcp trust.",
        onConfirm: () => setComposerFocused(true),
      })
      return
    }
    openMcpDialog(dialog, {
      servers,
      onSelect: (server) => {
        const configuredScope = server.scope === "user" || server.scope === "project"
        const trustedServer = server.status === "trusted" || server.status === "connected"
        const actions = [
          ...(server.status === "disabled" ? [] : [{
            title: trustedServer ? "Revoke session trust" : "Trust for this session",
            value: trustedServer ? "untrust" : "trust",
            description: "MCP calls still require per-call review",
          }]),
          ...(configuredScope ? [
            {
              title: server.status === "disabled" ? "Enable server" : "Disable server",
              value: server.status === "disabled" ? "enable" : "disable",
              description: `${server.scope} configuration`,
            },
            { title: "Remove server…", value: "remove", description: `${server.scope} configuration · confirmation required` },
          ] : []),
        ]
        if (actions.length === 0) {
          toast.info(`${server.status} · ${server.name}`, "MCP")
          setComposerFocused(true)
          return
        }
        openDialogSelect(dialog, {
          title: `MCP · ${server.name}`,
          options: actions,
          dismissOnSelect: false,
          onCancel: () => setComposerFocused(true),
          onSelect: (action) => {
            dialog.clear()
            if (action.value === "trust" || action.value === "untrust") {
              options.runTrustAction(action.value === "trust", server.name, context)
            } else if (action.value === "enable" || action.value === "disable" || action.value === "remove") {
              options.runConfigure(action.value, server.scope as McpConfigScope, server.name.slice("configured/".length), context)
            }
          },
          footer: "Trust permits connection only · review each tool call",
        })
      },
    })
  } catch (error) {
    if (!options.isCurrentContext()) {
      setComposerFocused(true)
      return
    }
    openDialogAlert(dialog, {
      title: "MCP",
      message: error instanceof Error ? error.message : "could not list MCP servers",
      onConfirm: () => setComposerFocused(true),
    })
  }
}
