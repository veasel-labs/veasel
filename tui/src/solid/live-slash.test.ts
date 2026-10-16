import { describe, expect, test } from "bun:test"
import { resolveLiveSlash } from "./live-slash"

describe("resolveLiveSlash", () => {
  test("passes through normal prompts", () => {
    expect(resolveLiveSlash("fix the flaky test")).toEqual({ kind: "passthrough" })
    expect(resolveLiveSlash("")).toEqual({ kind: "passthrough" })
  })

  test("routes connect, models, skills, mcp, help", () => {
    expect(resolveLiveSlash("/connect")).toEqual({ kind: "connect" })
    expect(resolveLiveSlash("  /connect  ")).toEqual({ kind: "connect" })
    expect(resolveLiveSlash("/models")).toEqual({ kind: "models" })
    expect(resolveLiveSlash("/skills")).toEqual({ kind: "skills", filter: "" })
    expect(resolveLiveSlash("/skills auth oauth")).toEqual({
      kind: "skills",
      filter: "auth oauth",
    })
    expect(resolveLiveSlash("/skill on user/demo")).toEqual({ kind: "skills", filter: "" })
    expect(resolveLiveSlash("/mcp")).toEqual({ kind: "mcp", filter: "" })
    expect(resolveLiveSlash("/mcp http")).toEqual({ kind: "mcp", filter: "http" })
    expect(resolveLiveSlash("/help")).toEqual({ kind: "help", advanced: false })
    expect(resolveLiveSlash("/help advanced")).toEqual({ kind: "help", advanced: true })
    expect(resolveLiveSlash("/?")).toEqual({ kind: "help", advanced: false })
  })

  test("routes theme, status, reviews, export, sessions", () => {
    expect(resolveLiveSlash("/theme")).toEqual({ kind: "theme", mode: "list" })
    expect(resolveLiveSlash("/theme ember")).toEqual({ kind: "theme", mode: "id", id: "ember" })
    expect(resolveLiveSlash("/usage")).toEqual({ kind: "status" })
    expect(resolveLiveSlash("/patches")).toEqual({ kind: "reviews" })
    expect(resolveLiveSlash("/commands pending")).toEqual({ kind: "reviews" })
    expect(resolveLiveSlash("/export")).toEqual({ kind: "export" })
    expect(resolveLiveSlash("/sessions")).toEqual({ kind: "session-list" })
  })

  test("marks unsupported known slashes and unknown typos", () => {
    expect(resolveLiveSlash("/mcp add user stdio demo echo hi")).toEqual({
      kind: "unsupported",
      command: "/mcp add user stdio demo echo hi",
    })
    expect(resolveLiveSlash("/plugins")).toEqual({
      kind: "unsupported",
      command: "/plugins",
    })
    expect(resolveLiveSlash("/not-a-real-command")).toEqual({
      kind: "unknown",
      command: "/not-a-real-command",
    })
  })
})
