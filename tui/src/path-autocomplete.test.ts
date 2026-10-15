import { describe, expect, test } from "bun:test"
import {
  completePathMention,
  filterWorkspacePaths,
  listWorkspacePaths,
  pathMentionAt,
  suggestWorkspacePaths,
} from "./path-autocomplete"

describe("pathMentionAt", () => {
  test("finds an @ token at the cursor and ignores emails", () => {
    expect(pathMentionAt("see @src/ma", 11)).toEqual({ start: 4, end: 11, query: "src/ma" })
    expect(pathMentionAt("@readme", 7)).toEqual({ start: 0, end: 7, query: "readme" })
    expect(pathMentionAt("hi @", 4)).toEqual({ start: 3, end: 4, query: "" })
    expect(pathMentionAt("mail user@host.com", 18)).toBeUndefined()
    expect(pathMentionAt("plain text", 5)).toBeUndefined()
  })
})

describe("filterWorkspacePaths", () => {
  test("ranks prefix matches before substring and basename hits", () => {
    const paths = ["src/main.ts", "src/help.ts", "docs/main.md", "README.md"]
    expect(filterWorkspacePaths(paths, "src/m").map((item) => item.path)).toEqual(["src/main.ts"])
    expect(filterWorkspacePaths(paths, "main").map((item) => item.path)).toEqual([
      "src/main.ts",
      "docs/main.md",
    ])
    expect(filterWorkspacePaths(paths, "read").map((item) => item.name)).toEqual(["@README.md"])
  })
})

describe("listWorkspacePaths", () => {
  test("walks a bounded tree and skips ignored directories", () => {
    const tree: Record<string, string[]> = {
      "/ws": ["src", "node_modules", "README.md", ".git"],
      "/ws/src": ["main.ts", "nested"],
      "/ws/src/nested": ["util.ts"],
      "/ws/node_modules": ["pkg"],
    }
    const dirs = new Set(["/ws", "/ws/src", "/ws/src/nested", "/ws/node_modules", "/ws/node_modules/pkg"])
    const paths = listWorkspacePaths(
      "/ws",
      (path) => tree[path] ?? [],
      (path) => dirs.has(path),
    )
    expect(paths).toEqual(["README.md", "src/main.ts", "src/nested/util.ts"])
  })
})

describe("suggestWorkspacePaths", () => {
  test("filters listed paths for the active query", () => {
    const suggestions = suggestWorkspacePaths("hel", "/ws", () => ["src/help.ts", "src/main.ts", "help.md"])
    expect(suggestions.map((item) => item.path)).toEqual(["help.md", "src/help.ts"])
  })
})

describe("completePathMention", () => {
  test("replaces the active @ token and leaves a trailing space at end of draft", () => {
    expect(completePathMention("see @src/ma", 11, {
      name: "@src/main.ts",
      description: "workspace path",
      path: "src/main.ts",
    })).toEqual({ value: "see @src/main.ts ", cursor: 17 })
    expect(completePathMention("@src/hel more", 8, {
      name: "@src/help.ts",
      description: "workspace path",
      path: "src/help.ts",
    })).toEqual({ value: "@src/help.ts more", cursor: 12 })
  })
})
