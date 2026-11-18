import { expect, test } from "bun:test"
import { cancelledTurnNote, completedTurnNote } from "./turn-outcome"

test("a plain completion has no extra note", () => {
  expect(completedTurnNote({ status: "completed" })).toBeUndefined()
  expect(completedTurnNote({ status: "completed", outcome: "completed", error: "" })).toBeUndefined()
})

test("denied approvals and unverified edits are surfaced on completion", () => {
  expect(
    completedTurnNote({
      status: "completed",
      outcome: "completed_with_denials",
      error: "Approvals: 1 expired (Bash). No changes were applied.",
    }),
  ).toBe("Done with denied approvals · Approvals: 1 expired (Bash). No changes were applied.")
  expect(
    completedTurnNote({
      status: "completed",
      outcome: "completed",
      error: "Applied: Edit math.js. These changes are not verified by Veasel; review the diff and run your tests.",
    }),
  ).toContain("not verified")
})

test("failed turns are left to the error path", () => {
  expect(completedTurnNote({ status: "failed", outcome: "partial", error: "x" })).toBeUndefined()
})

test("a cancelled turn that applied work says so", () => {
  expect(cancelledTurnNote({ status: "cancelled", outcome: "cancelled", error: "Turn cancelled." }, "Turn cancelled")).toBe(
    "Turn cancelled",
  )
  expect(
    cancelledTurnNote(
      { status: "cancelled", outcome: "cancelled", error: "Turn cancelled. Already applied before the stop: Edit math.js." },
      "Turn cancelled",
    ),
  ).toContain("Edit math.js")
})
