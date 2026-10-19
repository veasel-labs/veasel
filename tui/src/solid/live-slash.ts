import { isConnectCommand, isModelSettingsCommand } from "../help"
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
  | { kind: "mcp"; filter: string }
  | { kind: "help"; advanced: boolean }
  | { kind: "theme"; mode: "list" | "cycle" | "id"; id?: string }
  | { kind: "status" }
  | { kind: "reviews" }
  | { kind: "export" }
  | { kind: "session-list" }
  | { kind: "fork" }
  | { kind: "plugins"; filter: string }
  | { kind: "map"; hint: string }
  | { kind: "history-older" }
  | { kind: "history-hint" }
  | { kind: "unsupported"; command: string }
  | { kind: "unknown"; command: string }

const mcpManageRest =
  /^(add|remove|enable|disable|credential|credentials|oauth|trust|untrust)\b/i

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
  // /skill on|off|run … — open the picker; detailed toggles stay HTTP/palette follow-up.
  if (content === "/skill" || content.startsWith("/skill ")) {
    return { kind: "skills", filter: "" }
  }

  if (content === "/plugins" || content.startsWith("/plugins ")) {
    const filter = content === "/plugins" ? "" : content.slice("/plugins ".length).trim()
    return { kind: "plugins", filter }
  }
  if (content === "/plugin" || content.startsWith("/plugin ")) {
    // add/remove stay headless for now; bare /plugin opens the links dialog with a hint.
    return { kind: "plugins", filter: "" }
  }

  // Approvals: MCP tool calls, patches, shell commands → unified review panel.
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
