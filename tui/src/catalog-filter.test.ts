import { describe, expect, test } from "bun:test"
import {
  catalogFilterTokens,
  formatCatalogFilterEmpty,
  formatCatalogFilterHeader,
  isMcpManageRest,
  matchesCatalogFilter,
} from "./catalog-filter"

describe("catalogFilterTokens", () => {
  test("splits on punctuation and keeps path-like tokens", () => {
    expect(catalogFilterTokens("  Stdio · trusted/local  ")).toEqual(["stdio", "trusted/local"])
  })
})

describe("matchesCatalogFilter", () => {
  test("matches when every token hits the haystack", () => {
    const haystack = "● trusted  configured/search [stdio] · user scope"
    expect(matchesCatalogFilter(haystack, "")).toBe(true)
    expect(matchesCatalogFilter(haystack, "stdio")).toBe(true)
    expect(matchesCatalogFilter(haystack, "trusted stdio")).toBe(true)
    expect(matchesCatalogFilter(haystack, "http")).toBe(false)
    expect(matchesCatalogFilter(haystack, "search confi")).toBe(true)
  })
})

describe("formatCatalogFilterHeader", () => {
  test("states totals and filtered match counts", () => {
    expect(formatCatalogFilterHeader("MCP SERVERS", 3, 3, "")).toBe("MCP SERVERS  ·  3")
    expect(formatCatalogFilterHeader("AGENT SKILLS", 1, 4, "agents")).toBe(
      "AGENT SKILLS  ·  1/4 match “agents”",
    )
    expect(formatCatalogFilterHeader("PLUGIN LINKS", 0, 0, "")).toBe("PLUGIN LINKS")
  })
})

describe("formatCatalogFilterEmpty", () => {
  test("points operators back to a broader filter", () => {
    expect(formatCatalogFilterEmpty("skills", "zzzz")).toContain("zzzz")
    expect(formatCatalogFilterEmpty("MCP servers", "zzzz")).toContain("broader filter")
  })
})

describe("isMcpManageRest", () => {
  test("keeps manage verbs out of free-text filters", () => {
    expect(isMcpManageRest("add stdio foo cmd")).toBe(true)
    expect(isMcpManageRest("trust configured/search")).toBe(true)
    expect(isMcpManageRest("calls")).toBe(true)
    expect(isMcpManageRest("stdio trusted")).toBe(false)
    expect(isMcpManageRest("search")).toBe(false)
  })
})
