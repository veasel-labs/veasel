import { describe, expect, test } from "bun:test"
import { resolveLoopbackApiBase } from "./api-client"

describe("resolveLoopbackApiBase", () => {
  test("defaults to loopback port 4097", () => {
    expect(resolveLoopbackApiBase({})).toBe("http://127.0.0.1:4097")
  })

  test("honors VEASEL_PORT and VEASEL_API_URL on loopback", () => {
    expect(resolveLoopbackApiBase({ VEASEL_PORT: "5100" })).toBe("http://127.0.0.1:5100")
    expect(resolveLoopbackApiBase({ VEASEL_API_URL: "http://localhost:4200/" })).toBe(
      "http://localhost:4200",
    )
  })

  test("rejects non-loopback and credentialed URLs", () => {
    expect(() => resolveLoopbackApiBase({ VEASEL_API_URL: "http://example.com" })).toThrow(
      /loopback/,
    )
    expect(() =>
      resolveLoopbackApiBase({ VEASEL_API_URL: "http://user:pass@127.0.0.1:4097" }),
    ).toThrow(/loopback/)
    expect(() => resolveLoopbackApiBase({ VEASEL_API_URL: "https://127.0.0.1:4097" })).toThrow(
      /loopback/,
    )
  })
})
