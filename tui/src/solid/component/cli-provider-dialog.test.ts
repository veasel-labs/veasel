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
  expect(options[1]?.description).toContain("auth file detected; sign-in not verified")
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
