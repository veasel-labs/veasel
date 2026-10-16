import { resolve } from "node:path"
import { createSolidTransformPlugin } from "@opentui/solid/bun-plugin"

const args = process.argv.slice(2)
const useSolid = args.includes("--solid")
const positional = args.filter((arg) => arg !== "--solid")
const [target, outputPath] = positional
const supportedTargets = new Set(["bun-linux-x64", "bun-darwin-arm64", "bun-windows-x64"])
if (!target || !supportedTargets.has(target) || !outputPath) {
  throw new Error(
    `usage: bun run scripts/build-standalone.ts <${[...supportedTargets].join("|")}> <output-path> [--solid]`,
  )
}

const version = process.env.VEASEL_TUI_VERSION ?? "development"
const define: Record<string, string> = {
  "process.env.VEASEL_TUI_VERSION": JSON.stringify(version),
}
if (target.startsWith("bun-linux-")) {
  define["process.env.OPENTUI_LIBC"] = JSON.stringify("glibc")
}

const entry = useSolid
  ? resolve(import.meta.dir, "../src/solid/main.tsx")
  : resolve(import.meta.dir, "../src/main.ts")

const outfile = resolve(outputPath)
const result = await Bun.build({
  entrypoints: [entry],
  compile: { target, outfile },
  define,
  minify: true,
  plugins: useSolid ? [createSolidTransformPlugin()] : [],
})
if (!result.success) {
  for (const log of result.logs) console.error(log)
  process.exit(1)
}
console.log(
  `Built standalone ${target} TUI (${useSolid ? "solid" : "legacy"}) at ${outfile}`,
)
