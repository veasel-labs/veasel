# Durable turn outcomes (epic #689)

`session_operations.status` is the lifecycle of a turn. `outcome` says what the
turn actually did, derived only from facts Veasel recorded while it ran.

| outcome | meaning |
|---------|---------|
| `completed` | The turn finished with no denied or expired approvals. If edits were applied the summary lists them and says they are not verified. |
| `completed_with_denials` | The turn finished, but at least one approval was denied or expired. The summary says whether anything was applied. |
| `partial` | The turn stopped early (error, timeout, crash) after edits or approved commands had already been applied. |
| `failed` | The turn stopped early and nothing was applied. |
| `cancelled` | The user cancelled; work applied before the stop is listed. |
| `uncertain` | Effects cannot be established (server stopped mid-turn, or a provider whose tool results Veasel cannot observe was approved and then failed). |

Turns recorded before migration 32 have an empty `outcome`; their truth is
`status` alone.

## Facts

- Approval decisions (approved / denied / expired) are recorded by the
  approval callback for every installed-CLI provider.
- Applied side effects are observed from the CLI's own tool results, which
  Veasel can read for Claude stream-json only (`effects_observed`). An edit
  counts when the CLI reports its tool result without `is_error`; a command
  counts only when it was approval-gated and succeeded. Commands are recorded by
  executable only (`Bash (git)`), never with arguments.
- Veasel does not run or read tests for CLI turns. `verification` is always
  `not_reported`, and summaries say applied changes are not verified.

## Approval expiry

An unanswered approval now expires after `VEASEL_CLI_APPROVAL_TIMEOUT_SECONDS`
(default 60, max 3600) or the turn deadline, whichever is sooner. It is denied
in-band, so the CLI can finish its turn, instead of the whole turn timing out
underneath the approval after edits were applied. Nothing is ever
auto-approved, and approvals still carry the CLI's exact input.

## Surfaces

- `GET /v1/sessions/:id/operations[/:operation_id]`: `outcome`,
  `outcome_summary`, `outcome_facts`.
- `session.turn_completed` events: `outcome`, and `error` carries the summary.
- Desktop shows "This turn stopped early, but changes were applied", "Done,
  with denied approvals", or "Result uncertain" with the summary; the TUI status
  line shows the same note.

## Rollback and downgrade

Migration 32 is additive: `ALTER TABLE session_operations ADD COLUMN outcome`
(with its own `CHECK`) and `outcome_detail`. `status` and its `CHECK` are
untouched, so a v31 (or v30) binary opens a v32 database, ignores the new
columns, and keeps writing valid rows (`outcome` defaults to empty). No table is
rebuilt. To undo completely, restore the pre-upgrade `veasel.sqlite3`.
