/** @jsxImportSource @opentui/solid */
import type { useDialog } from "../ui/dialog"
import { openDialogAlert } from "../ui/dialog-alert"

/** OpenCode pairs mobile/desktop via server.pair — Veasel has no equivalent HTTP surface. */
export const PAIRING_DOC = "docs/compatibility/tui-device-pairing.md"

export function openPairDialog(dialog: ReturnType<typeof useDialog>) {
  openDialogAlert(dialog, {
    title: "Device pairing",
    message:
      "Not available in Veasel. OpenCode pairs auxiliary clients through server.pair; Veasel binds the agent to loopback HTTP only. See docs/compatibility/tui-device-pairing.md for the parity decision.",
  })
}
