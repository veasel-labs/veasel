import type { ApiShellCommandSummary } from "../api-client"

/** Finished shell proposals that captured stdout/stderr for the output dialog. */
export function shellCommandsWithOutput(
  commands: ApiShellCommandSummary[],
): ApiShellCommandSummary[] {
  return commands.filter(
    (item) =>
      item.status !== "pending"
      && typeof item.output === "string"
      && item.output.trim().length > 0,
  )
}
