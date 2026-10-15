import { expect, test } from "bun:test"
import { sessionEscapeAction } from "./session-escape"

test("Esc prefers cancel, then dismiss notice, then leave", () => {
  expect(sessionEscapeAction({ sending: true, hasNotice: true })).toBe("cancel-turn")
  expect(sessionEscapeAction({ sending: false, hasNotice: true })).toBe("dismiss-notice")
  expect(sessionEscapeAction({ sending: false, hasNotice: false })).toBe("leave-session")
})
