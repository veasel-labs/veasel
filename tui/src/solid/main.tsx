/** @jsxImportSource @opentui/solid */
import { render } from "@opentui/solid"
import { resolveLoopbackApiBase, VeaselApiClient } from "../api-client"
import { formatTuiHelp, formatTuiVersion, parseTuiCliAction } from "../cli"
import { LiveApp } from "./live-app"

const tuiVersion = process.env.VEASEL_TUI_VERSION ?? "development"
const tuiCliAction = parseTuiCliAction(process.argv)
if (tuiCliAction === "help") {
  console.log(formatTuiHelp(tuiVersion))
  process.exit(0)
}
if (tuiCliAction === "version") {
  console.log(formatTuiVersion(tuiVersion))
  process.exit(0)
}

const controller = new AbortController()
const apiBase = resolveLoopbackApiBase()
const api = new VeaselApiClient(apiBase, controller.signal)

const quit = () => {
  controller.abort()
  process.exit(0)
}

process.on("SIGINT", quit)
process.on("SIGTERM", quit)

await render(() => (
  <LiveApp
    api={api}
    directory={process.env.VEASEL_PROJECT_DIR ?? process.cwd()}
    onQuit={quit}
  />
))
