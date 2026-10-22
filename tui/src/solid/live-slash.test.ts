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
    expect(resolveLiveSlash("/skill on user/demo")).toEqual({ kind: "skill-action", action: "on", key: "user/demo" })
    expect(resolveLiveSlash("/skill off user/demo")).toEqual({ kind: "skill-action", action: "off", key: "user/demo" })
    expect(resolveLiveSlash("/skill run user/demo")).toEqual({ kind: "skill-action", action: "run", key: "user/demo" })
    expect(resolveLiveSlash("/mcp")).toEqual({ kind: "mcp", filter: "" })
    expect(resolveLiveSlash("/mcp http")).toEqual({ kind: "mcp", filter: "http" })
    expect(resolveLiveSlash("/mcp trust configured/echo-tools")).toEqual({
      kind: "mcp-trust",
      trusted: true,
      key: "configured/echo-tools",
    })
    expect(resolveLiveSlash("/mcp untrust local-kit/calendar")).toEqual({
      kind: "mcp-trust",
      trusted: false,
      key: "local-kit/calendar",
    })
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
    expect(resolveLiveSlash("/fork")).toEqual({ kind: "fork" })
  })

  test("routes mcp calls, patch, and command into reviews", () => {
    expect(resolveLiveSlash("/mcp calls")).toEqual({ kind: "reviews" })
    expect(resolveLiveSlash("/mcp call show deadbeef-dead-4ead-8ead-deadbeefdead")).toEqual({
      kind: "reviews",
    })
    expect(resolveLiveSlash("/patch approve deadbeef-dead-4ead-8ead-deadbeefdead")).toEqual({
      kind: "reviews",
    })
    expect(resolveLiveSlash("/command show deadbeef-dead-4ead-8ead-deadbeefdead")).toEqual({
      kind: "reviews",
    })
  })

  test("routes plugins, map, and history", () => {
    expect(resolveLiveSlash("/plugins")).toEqual({ kind: "plugins", filter: "" })
    expect(resolveLiveSlash("/plugins auth")).toEqual({ kind: "plugins", filter: "auth" })
    expect(resolveLiveSlash("/plugin")).toEqual({ kind: "plugins", filter: "" })
    expect(resolveLiveSlash("/map")).toEqual({ kind: "map", hint: "" })
    expect(resolveLiveSlash("/map boot")).toEqual({ kind: "map", hint: "boot" })
    expect(resolveLiveSlash("/history older")).toEqual({ kind: "history-older" })
    expect(resolveLiveSlash("/history")).toEqual({ kind: "history-hint" })
  })

  test("marks unsupported known slashes and unknown typos", () => {
    expect(resolveLiveSlash("/mcp add user stdio demo echo hi")).toEqual({
      kind: "unsupported",
      command: "/mcp add user stdio demo echo hi",
    })
    expect(resolveLiveSlash("/theme reload")).toEqual({
      kind: "unsupported",
      command: "/theme reload",
    })
    expect(resolveLiveSlash("/skill whatever user/demo")).toEqual({
      kind: "unsupported",
      command: "/skill whatever user/demo",
    })
    expect(resolveLiveSlash("/not-a-real-command")).toEqual({
      kind: "unknown",
      command: "/not-a-real-command",
    })
  })
})
