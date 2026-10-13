import { resolve } from "node:path"

const [target, outputPath] = process.argv.slice(2)
const supportedTargets = new Set(["bun-linux-x64", "bun-darwin-arm64", "bun-windows-x64"])
if (!target || !supportedTargets.has(target) || !outputPath) {
  throw new Error(
    `usage: bun run scripts/build-standalone.ts <${[...supportedTargets].join("|")}> <output-path>`,
  )
}

const version = process.env.VEASEL_TUI_VERSION ?? "development"
const define: Record<string, string> = {
  "process.env.VEASEL_TUI_VERSION": JSON.stringify(version),
}
if (target.startsWith("bun-linux-")) {
  define["process.env.OPENTUI_LIBC"] = JSON.stringify("glibc")
}

const outfile = resolve(outputPath)
const result = await Bun.build({
  entrypoints: [resolve(import.meta.dir, "../src/main.ts")],
  compile: { target, outfile },
  define,
  minify: true,
})
if (!result.success) {
  for (const log of result.logs) console.error(log)
  process.exit(1)
}
console.log(`Built standalone ${target} TUI at ${outfile}`)
