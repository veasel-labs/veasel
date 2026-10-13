export type TuiCliAction = "run" | "help" | "version"

export function parseTuiCliAction(argv: readonly string[]): TuiCliAction {
  if (argv.includes("--help") || argv.includes("-h")) return "help"
  if (argv.includes("--version") || argv.includes("-v")) return "version"
  return "run"
}

export function formatTuiHelp(version: string): string {
  return `Veasel Code Terminal ${version}\n\nUsage: veasel-tui [--help] [--version]\n\nLaunch Veasel's interactive terminal client.`
}

export function formatTuiVersion(version: string): string {
  return `Veasel Code Terminal ${version}`
}
