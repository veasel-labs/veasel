import { describe, expect, test } from "bun:test"
import {
  defaultToastDurationMs,
  toastBorderColor,
  toastVariantLabel,
} from "./ui/toast"
import { solidMint } from "./theme"

describe("Solid toast helpers", () => {
  test("maps variants to mint status / brand borders", () => {
    expect(toastBorderColor("info")).toBe(solidMint.brand)
    expect(toastBorderColor("success")).toBe(solidMint.statusOk)
    expect(toastBorderColor("warning")).toBe(solidMint.statusWarn)
    expect(toastBorderColor("error")).toBe(solidMint.statusError)
  })

  test("labels variants for screen-reader-friendly chrome", () => {
    expect(toastVariantLabel("info")).toBe("info")
    expect(toastVariantLabel("success")).toBe("ok")
    expect(toastVariantLabel("warning")).toBe("warn")
    expect(toastVariantLabel("error")).toBe("error")
  })

  test("defaults duration to five seconds", () => {
    expect(defaultToastDurationMs).toBe(5000)
  })
})
