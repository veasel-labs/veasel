import { expect, test } from "bun:test"
import { spawn } from "node:child_process"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const tuiRoot = dirname(dirname(fileURLToPath(import.meta.url)))

test("drives the real terminal through setup, completion, diff review, shell review, MCP review, long session lists, and session switching", async () => {
  const result = await new Promise<{ code: number | null, stderr: string }>((resolve, reject) => {
    const child = spawn("python3", [join(tuiRoot, "scripts/exercise-keyboard.py")], {
      cwd: tuiRoot,
    })
    let stderr = ""
    child.stderr.setEncoding("utf8")
    child.stderr.on("data", (chunk: string) => {
      stderr += chunk
    })
    child.on("error", reject)
    child.on("close", (code) => resolve({ code, stderr }))
  })
  expect(result.stderr).toBe("")
  expect(result.code).toBe(0)
}, 160_000)
