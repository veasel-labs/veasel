import { describe, expect, test } from "bun:test"
import {
  calculatePathFrecency,
  createPathFrecencyStore,
  normalizePathFrecencyKey,
  parsePathFrecency,
  pathFrecencyFilePath,
} from "./path-frecency"

describe("normalizePathFrecencyKey", () => {
  test("normalizes slashes and leading ./", () => {
    expect(normalizePathFrecencyKey("./src\\main.ts")).toBe("src/main.ts")
    expect(normalizePathFrecencyKey("  docs/a.md  ")).toBe("docs/a.md")
  })
})

describe("pathFrecencyFilePath", () => {
  test("prefers XDG_STATE_HOME when set", () => {
    expect(pathFrecencyFilePath({ XDG_STATE_HOME: "/state" }, "/home/u")).toBe(
      "/state/veasel/path-frecency.jsonl",
    )
    expect(pathFrecencyFilePath({}, "/home/u")).toBe(
      "/home/u/.local/state/veasel/path-frecency.jsonl",
    )
  })
})

describe("calculatePathFrecency", () => {
  test("decays with age and returns zero for empty entries", () => {
    const now = 1_000_000_000_000
    expect(calculatePathFrecency(undefined, now)).toBe(0)
    expect(calculatePathFrecency({ frequency: 2, lastOpen: now }, now)).toBe(2)
    expect(calculatePathFrecency({ frequency: 2, lastOpen: now - 86_400_000 }, now)).toBe(1)
  })
})

describe("parsePathFrecency", () => {
  test("keeps the latest line per path and skips corrupt rows", () => {
    const text = [
      JSON.stringify({ path: "a.ts", frequency: 1, lastOpen: 10 }),
      "not-json",
      JSON.stringify({ path: "b.ts", frequency: 0, lastOpen: 20 }),
      JSON.stringify({ path: "a.ts", frequency: 3, lastOpen: 30 }),
      "",
    ].join("\n")
    expect(parsePathFrecency(text)).toEqual({
      "a.ts": { path: "a.ts", frequency: 3, lastOpen: 30 },
    })
  })
})

describe("createPathFrecencyStore", () => {
  test("loads, scores, bumps, and appends JSONL", () => {
    let file = `${JSON.stringify({ path: "old.ts", frequency: 4, lastOpen: 1_000 })}\n`
    const writes: string[] = []
    const appends: string[] = []
    let now = 1_000
    const store = createPathFrecencyStore({
      env: { XDG_STATE_HOME: "/state" },
      home: "/home/u",
      now: () => now,
      readFile: () => file,
      writeFile: (_path, data) => {
        writes.push(data)
        file = data
      },
      appendFile: (_path, data) => {
        appends.push(data)
        file += data
      },
    })
    expect(store.get("old.ts")).toBe(4)
    now = 1_000 + 86_400_000
    expect(store.get("old.ts")).toBe(2)
    store.bump("src/main.ts")
    expect(store.get("src/main.ts")).toBe(1)
    expect(appends).toHaveLength(1)
    expect(JSON.parse(appends[0]!.trim())).toEqual({
      path: "src/main.ts",
      frequency: 1,
      lastOpen: now,
    })
    expect(writes).toHaveLength(0)
  })

  test("ignores absolute paths on bump", () => {
    const store = createPathFrecencyStore({
      env: {},
      home: "/home/u",
      readFile: () => {
        throw new Error("missing")
      },
      writeFile: () => {},
      appendFile: () => {
        throw new Error("should not append")
      },
    })
    store.bump("/etc/passwd")
    expect(store.snapshot()).toEqual({})
  })
})
