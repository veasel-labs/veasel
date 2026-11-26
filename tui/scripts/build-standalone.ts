import { copyFileSync, existsSync, mkdirSync, readdirSync, rmSync, statSync } from "node:fs"
import { dirname, resolve } from "node:path"
import { createSolidTransformPlugin } from "@opentui/solid/bun-plugin"

const args = process.argv.slice(2)
const useClassic = args.includes("--classic")
const positional = args.filter((arg) => arg !== "--classic" && arg !== "--solid")
const [target, outputPath] = positional
const supportedTargets = new Set(["bun-linux-x64", "bun-darwin-arm64", "bun-windows-x64"])
if (!target || !supportedTargets.has(target) || !outputPath) {
  throw new Error(
    `usage: bun run scripts/build-standalone.ts <${[...supportedTargets].join("|")}> <output-path> [--classic]`,
  )
}

const nativeAssets: Record<string, { packageName: string; filename: string }> = {
  "bun-linux-x64": { packageName: "core-linux-x64", filename: "libopentui.so" },
  "bun-darwin-arm64": { packageName: "core-darwin-arm64", filename: "libopentui.dylib" },
  "bun-windows-x64": { packageName: "core-win32-x64", filename: "opentui.dll" },
}

const version = process.env.VEASEL_TUI_VERSION ?? "development"
const define: Record<string, string> = {
  "process.env.VEASEL_TUI_VERSION": JSON.stringify(version),
}
if (target.startsWith("bun-linux-")) {
  define["process.env.OPENTUI_LIBC"] = JSON.stringify("glibc")
}

// Solid OpenTUI is the default standalone entry. `--classic` remains an
// emergency escape hatch for the imperative shell.
const entry = useClassic
  ? resolve(import.meta.dir, "../src/classic-main.ts")
  : resolve(import.meta.dir, "../src/entry.ts")

const outfile = resolve(outputPath)
const result = await Bun.build({
  entrypoints: [entry],
  compile: { target, outfile },
  define,
  minify: true,
  plugins: useClassic ? [] : [createSolidTransformPlugin()],
})
if (!result.success) {
  for (const log of result.logs) console.error(log)
  process.exit(1)
}

// OpenTUI 0.8.3's default resolver points into Bun's virtual filesystem in a
// compiled executable. dlopen cannot load that virtual path, so ship the exact
// native artifact from the locked platform package beside the standalone TUI.
const nativeAsset = nativeAssets[target]
const nativeSource = resolve(import.meta.dir, `../node_modules/@opentui/${nativeAsset.packageName}/${nativeAsset.filename}`)
if (!existsSync(nativeSource) || statSync(nativeSource).size === 0) {
  throw new Error(`OpenTUI native library is missing or empty: ${nativeSource}`)
}
const nativeOutput = resolve(dirname(outfile), nativeAsset.filename)
copyFileSync(nativeSource, nativeOutput)
if (statSync(nativeOutput).size !== statSync(nativeSource).size) {
  throw new Error(`OpenTUI native library copy was incomplete: ${nativeOutput}`)
}
const packageDirectory = dirname(nativeSource)
const legalOutput = resolve(dirname(outfile), "opentui-licenses")
rmSync(legalOutput, { recursive: true, force: true })
mkdirSync(legalOutput, { recursive: true })
const legalFiles = readdirSync(packageDirectory).filter((name) =>
  /^(LICENSE|AUTHORS|PATENTS)(-|$)/.test(name)
  || name === "FFMPEG-SOURCE.md"
  || name === "README.md"
  || name === "package.json",
)
if (!legalFiles.includes("LICENSE")) {
  throw new Error(`OpenTUI license notices are missing from ${packageDirectory}`)
}
for (const filename of legalFiles) {
  copyFileSync(resolve(packageDirectory, filename), resolve(legalOutput, filename))
}
console.log(
  `Built standalone ${target} TUI (${useClassic ? "classic" : "solid"}) at ${outfile} with ${nativeOutput} and ${legalFiles.length} notices`,
)
