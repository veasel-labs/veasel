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
  | { kind: "unsupported"; command: string }
  | { kind: "unknown"; command: string }

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

  if (content === "/skills" || content.startsWith("/skills ")) {
    const filter = content === "/skills" ? "" : content.slice("/skills ".length).trim()
    return { kind: "skills", filter }
  }
  // /skill on|off|run … — open the picker; detailed toggles stay HTTP/palette follow-up.
  if (content === "/skill" || content.startsWith("/skill ")) {
    return { kind: "skills", filter: "" }
  }

  if (content === "/mcp" || content.startsWith("/mcp ")) {
    // Subcommands like /mcp add stay unsupported until headless parity; bare list opens dialog.
    const rest = content === "/mcp" ? "" : content.slice("/mcp ".length).trim()
    if (!rest || !/^(add|remove|enable|disable|credential|credentials|oauth|call|calls|trust|untrust)\b/i.test(rest)) {
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
  if (content === "/patches" || content.startsWith("/patches ") || content === "/commands" || content.startsWith("/commands ")) {
    return { kind: "reviews" }
  }
  if (content === "/export" || content.startsWith("/export ")) return { kind: "export" }
  if (content === "/sessions" || content === "/session") return { kind: "session-list" }

  if (knownSlashName(content)) {
    return { kind: "unsupported", command: content }
  }
  return { kind: "unknown", command: content }
}
