import { isConnectCommand, isModelSettingsCommand } from "../help"
import type { ActiveReviewKind } from "../active-review"
import { slashCommands } from "../slash-commands"

/**
 * LiveApp composer slash routing — maps typed `/commands` onto Solid dialogs
 * instead of sending them as chat turns (classic-main parity for the hot path).
 */

export type LiveSlashAction =
  | { kind: "passthrough" }
  | { kind: "connect" }
  | { kind: "models" }
  | { kind: "skills"; filter: string }
  | { kind: "skill-action"; action: "on" | "off" | "run"; key?: string }
  | { kind: "mcp"; filter: string }
  | { kind: "mcp-trust"; trusted: boolean; key?: string }
  | { kind: "mcp-add-wizard" }
  | { kind: "mcp-add"; scope: "user" | "project"; name: string; transport: "stdio" | "streamable-http"; command?: string; args?: string[]; url?: string }
  | { kind: "mcp-configure"; action: "remove" | "enable" | "disable"; scope: "user" | "project"; name: string }
  | { kind: "help"; advanced: boolean }
  | { kind: "theme"; mode: "list" | "cycle" | "id"; id?: string }
  | { kind: "status" }
  | { kind: "reviews"; target?: { kind: ActiveReviewKind; id: string } }
  | { kind: "export" }
  | { kind: "session-list" }
  | { kind: "fork" }
  | { kind: "plugins"; filter: string }
  | { kind: "plugin-add"; path?: string; replace: boolean }
  | { kind: "plugin-remove"; name: string }
  | { kind: "map"; hint: string }
  | { kind: "history-older" }
  | { kind: "history-hint" }
  | { kind: "runs" }
  | { kind: "unsupported"; command: string }
  | { kind: "unknown"; command: string }

const mcpManageRest =
  /^(add|remove|enable|disable|credential|credentials|oauth|trust|untrust)\b/i

export function splitMcpArgs(raw: string): string[] {
  const args: string[] = []
  const matcher = /"([^"\\]*(?:\\.[^"\\]*)*)"|'([^'\\]*(?:\\.[^'\\]*)*)'|(\S+)/g
  for (const match of raw.matchAll(matcher)) {
    args.push((match[1] ?? match[2] ?? match[3] ?? "").replace(/\\(["'\\])/g, "$1"))
  }
  return args
}

function knownSlashName(name: string): boolean {
  return slashCommands.some(
    (command) => command.name === name || name.startsWith(`${command.name} `),
  )
}

/** Resolve a submitted composer line into a LiveApp slash action. */
export function resolveLiveSlash(input: string): LiveSlashAction {
  const content = input.trim()
  if (!content.startsWith("/")) return { kind: "passthrough" }

  if (content === "/help" || content === "/?") {
    return { kind: "help", advanced: false }
  }
  if (content === "/help advanced") {
    return { kind: "help", advanced: true }
  }
  if (isConnectCommand(content)) return { kind: "connect" }
  if (isModelSettingsCommand(content)) return { kind: "models" }

  if (content === "/runs" || content === "/history runs") return { kind: "runs" }
  if (content === "/history older") return { kind: "history-older" }
  if (/^\/history(?:\s|$)/.test(content)) return { kind: "history-hint" }

  if (content === "/map" || content.startsWith("/map ")) {
    const hint = content === "/map" ? "" : content.slice("/map ".length).trim()
    return { kind: "map", hint }
  }

  if (content === "/skills" || content.startsWith("/skills ")) {
    const filter = content === "/skills" ? "" : content.slice("/skills ".length).trim()
    return { kind: "skills", filter }
  }
  if (content === "/skill") {
    return { kind: "skills", filter: "" }
  }
  if (content.startsWith("/skill ")) {
    const match = /^\/skill\s+(on|off|run)(?:\s+(.+))?$/i.exec(content)
    if (!match) return { kind: "unsupported", command: content }
    const key = match[2]?.trim()
    return { kind: "skill-action", action: match[1]!.toLowerCase() as "on" | "off" | "run", key }
  }

  if (content === "/plugins" || content.startsWith("/plugins ")) {
    const filter = content === "/plugins" ? "" : content.slice("/plugins ".length).trim()
    return { kind: "plugins", filter }
  }
  const pluginAdd = /^\/plugin\s+add(?:\s+([\s\S]*))?$/i.exec(content)
  if (pluginAdd) {
    let rest = pluginAdd[1]?.trim() ?? ""
    const replace = /^--replace(?:\s|$)/i.test(rest)
    if (replace) rest = rest.replace(/^--replace\s*/i, "")
    if ((rest.startsWith('"') && rest.endsWith('"')) || (rest.startsWith("'") && rest.endsWith("'"))) {
      rest = rest.slice(1, -1)
    }
    return { kind: "plugin-add", path: rest || undefined, replace }
  }
  const pluginRemove = /^\/plugin\s+remove\s+(\S+)$/i.exec(content)
  if (pluginRemove) return { kind: "plugin-remove", name: pluginRemove[1]! }
  if (content === "/plugin" || content.startsWith("/plugin ")) {
    // Bare /plugin opens the managed links dialog; add and removal are explicit.
    return { kind: "plugins", filter: "" }
  }

  // Approvals: MCP tool calls, patches, shell commands → unified review panel.
  const patchTarget = /^\/patch\s+(?:show|approve|reject)\s+(\S+)$/i.exec(content)
  if (patchTarget) {
    return { kind: "reviews", target: { kind: "patch", id: patchTarget[1]! } }
  }
  const commandTarget = /^\/command\s+(?:show|approve|reject)\s+(\S+)$/i.exec(content)
  if (commandTarget) {
    return { kind: "reviews", target: { kind: "command", id: commandTarget[1]! } }
  }
  const mcpCallTarget = /^\/mcp\s+call\s+(?:show|approve|reject)\s+(\S+)$/i.exec(content)
  if (mcpCallTarget) {
    return { kind: "reviews", target: { kind: "mcp", id: mcpCallTarget[1]! } }
  }
  if (
    content === "/mcp calls"
    || /^\/mcp call\b/i.test(content)
    || content === "/patches"
    || content.startsWith("/patches ")
    || content.startsWith("/patch ")
    || content === "/commands"
    || content.startsWith("/commands ")
    || content.startsWith("/command ")
  ) {
    return { kind: "reviews" }
  }

  if (content === "/mcp" || content.startsWith("/mcp ")) {
    const rest = content === "/mcp" ? "" : content.slice("/mcp ".length).trim()
    if (rest.toLowerCase() === "add") return { kind: "mcp-add-wizard" }
    const addStdio = /^add(?:\s+(user|project))?\s+stdio\s+([a-z0-9][a-z0-9.-]*[a-z0-9]|[a-z0-9])\s+(\S+)(?:\s+([\s\S]+))?$/i.exec(rest)
    if (addStdio) return {
      kind: "mcp-add", scope: addStdio[1]?.toLowerCase() === "project" ? "project" : "user",
      transport: "stdio", name: addStdio[2]!, command: addStdio[3]!, args: addStdio[4] ? splitMcpArgs(addStdio[4]) : [],
    }
    const addHttp = /^add(?:\s+(user|project))?\s+http\s+([a-z0-9][a-z0-9.-]*[a-z0-9]|[a-z0-9])\s+(\S+)$/i.exec(rest)
    if (addHttp) return {
      kind: "mcp-add", scope: addHttp[1]?.toLowerCase() === "project" ? "project" : "user",
      transport: "streamable-http", name: addHttp[2]!, url: addHttp[3]!,
    }
    const configure = /^(remove|enable|disable)(?:\s+(user|project))?\s+([a-z0-9][a-z0-9.-]*[a-z0-9]|[a-z0-9])$/i.exec(rest)
    if (configure) return {
      kind: "mcp-configure", action: configure[1]!.toLowerCase() as "remove" | "enable" | "disable",
      scope: configure[2]?.toLowerCase() === "project" ? "project" : "user", name: configure[3]!,
    }
    const trustMatch = /^\/(?:mcp)\s+(trust|untrust)(?:\s+(.+))?$/i.exec(content)
    if (trustMatch) {
      return {
        kind: "mcp-trust",
        trusted: trustMatch[1]!.toLowerCase() === "trust",
        key: trustMatch[2]?.trim(),
      }
    }
    if (!rest || !mcpManageRest.test(rest)) {
      return { kind: "mcp", filter: rest }
    }
    return { kind: "unsupported", command: content }
  }

  if (content === "/theme") return { kind: "theme", mode: "list" }
  const themeMatch = /^\/theme\s+([a-z][a-z0-9-]*)$/i.exec(content)
  if (themeMatch) {
    const id = themeMatch[1]!.toLowerCase()
    if (id === "reload" || id === "open") {
      return { kind: "unsupported", command: content }
    }
    return { kind: "theme", mode: "id", id }
  }

  if (content === "/usage" || content === "/status") return { kind: "status" }
  if (content === "/export" || content.startsWith("/export ")) return { kind: "export" }
  if (content === "/sessions" || content === "/session") return { kind: "session-list" }
  if (content === "/fork") return { kind: "fork" }

  if (knownSlashName(content)) {
    return { kind: "unsupported", command: content }
  }
  return { kind: "unknown", command: content }
}
