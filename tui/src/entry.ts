import { formatTuiHelp, formatTuiVersion, parseTuiCliAction } from "./cli"

const tuiCliAction = parseTuiCliAction(process.argv)
const tuiVersion = process.env.VEASEL_TUI_VERSION ?? "development"

if (tuiCliAction === "help") {
  console.log(formatTuiHelp(tuiVersion))
  process.exit(0)
}
if (tuiCliAction === "version") {
  console.log(formatTuiVersion(tuiVersion))
  process.exit(0)
}

await import("./solid/main")
