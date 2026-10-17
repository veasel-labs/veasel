/** @jsxImportSource @opentui/solid */
import { resolveLoopbackApiBase, VeaselApiClient } from "../api-client"
import { formatTuiHelp, formatTuiVersion, parseTuiCliAction } from "../cli"

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

// Load the renderer and the full UI graph only when a session actually
// launches, so --version/--help stay fast and light.
const [{ render }, { LiveApp }] = await Promise.all([
  import("@opentui/solid"),
  import("./live-app"),
])

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
