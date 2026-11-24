import { expect, test } from "bun:test"
import { cliProviderOptions } from "./cli-provider-dialog"
import type { ApiCliProvider } from "../../api-client"

const provider = (overrides: Partial<ApiCliProvider> = {}): ApiCliProvider => ({
  id: "opencode",
  name: "OpenCode",
  exec: "opencode",
  protocol: "acp",
  installed: true,
  version: "2.3.2",
  auth_probe_present: true,
  auth_state: "probe-present",
  permission_modes: ["ask"],
  session_resume_verified: true,
  usage_reporting: "adapter-reported",
  ...overrides,
})

test("CLI runner picker offers the default and installed providers with honest auth wording", () => {
  const options = cliProviderOptions([
    provider(),
    provider({ id: "codex", name: "Codex", installed: false }),
  ])
  expect(options.map((option) => option.value)).toEqual(["", "opencode"])
  expect(options[1]?.description).toContain("credentials detected; sign-in unverified")
})

test("CLI runner picker identifies verified native subscription login without claiming quota", () => {
  const options = cliProviderOptions([
    provider({
      id: "claude-code",
      name: "Claude Code",
      auth_state: "verified",
      auth_method: "claude.ai",
      account_mode: "max",
    }),
  ])
  expect(options[1]?.description).toContain("signed in with Claude.ai · MAX plan; quota unknown")
})

test("CLI runner picker keeps file presence distinct from a reported sign-out", () => {
  const present = cliProviderOptions([provider({ auth_state: "probe-present" })])
  const signedOut = cliProviderOptions([provider({ auth_state: "signed-out" })])
  expect(present[1]?.description).toContain("credentials detected; sign-in unverified")
  expect(signedOut[1]?.description).toContain("native CLI reports signed out")
})

test("CLI runner picker fails closed when no CLI is installed", () => {
  const options = cliProviderOptions([provider({ installed: false })])
  expect(options.map((option) => option.value)).toEqual(["", "__none__"])
  expect(options[1]).toMatchObject({ disabled: true, value: "__none__" })
})

test("CLI runner picker disables providers that cannot honor the session permission mode", () => {
  const options = cliProviderOptions([provider()], "plan")
  expect(options[1]).toMatchObject({
    disabled: true,
    description: expect.stringContaining("unavailable in plan mode"),
  })
})

test("CLI version output cannot inject terminal controls into the picker", () => {
  const options = cliProviderOptions([provider({ version: "2.3.2\u001b[31m" })])
  expect(options[1]?.description).not.toContain("\u001b")
})
