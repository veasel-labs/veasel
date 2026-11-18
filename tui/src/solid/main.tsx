/** @jsxImportSource @opentui/solid */
import { resolveLoopbackApiBase, VeaselApiClient } from "../api-client"
import { connectAuthenticated } from "../backend-auth"

// Load the renderer and full UI graph only after the lightweight CLI entry
// has selected the interactive path.
const [{ render }, { LiveApp }] = await Promise.all([
  import("@opentui/solid"),
  import("./live-app"),
])

const controller = new AbortController()
const apiBase = resolveLoopbackApiBase()
try {
  await connectAuthenticated(apiBase)
} catch (error) {
  console.error(`veasel: ${error instanceof Error ? error.message : String(error)}`)
  process.exit(1)
}
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
