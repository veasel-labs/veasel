import { existsSync, realpathSync } from "node:fs"
import { dirname, join } from "node:path"
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

// Bun compile embeds imported files under /$bunfs. OpenTUI's FFI loader needs
// a real filesystem path, so prefer the package's adjacent native sidecar.
// Keep OpenTUI's documented override available for deliberate custom builds.
if (!process.env.OPENTUI_LIB_PATH) {
  const nativeLibrary = process.platform === "win32"
    ? "opentui.dll"
    : process.platform === "darwin"
      ? "libopentui.dylib"
      : "libopentui.so"
  const executablePath = realpathSync(process.execPath)
  const adjacentLibrary = join(dirname(executablePath), nativeLibrary)
  if (existsSync(adjacentLibrary)) process.env.OPENTUI_LIB_PATH = adjacentLibrary
}

await import("./solid/main")
