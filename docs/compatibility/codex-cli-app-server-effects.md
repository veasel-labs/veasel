# Codex app-server effect receipts

**Inspected upstream:** [`openai/codex` `rust-v0.172.0`](https://github.com/openai/codex/tree/3d86e43b075adeba2193ec5c22ac92f55afd82e6)  
**Exact commit:** `3d86e43b075adeba2193ec5c22ac92f55afd82e6`

Veasel consumes the installed Codex CLI's app-server JSON-RPC lifecycle; no
Codex implementation code is copied. `item/started` and `item/completed` carry
the `commandExecution`, `fileChange`, and provider-tool item records. The
adapter reduces those records into redacted `TurnFacts` and public outcome
receipts; those receipts store action categories and omit command arguments,
command output, file paths, and patch contents. Pending command approvals retain
their request parameters for review. For v2 file changes, the approval request
contains identity and explanatory fields but not the patch: Veasel correlates
`item/fileChange/patchUpdated` by exact `threadId`, `turnId`, and `itemId`, then
persists the bounded `changes` snapshot with the approval. A missing, stale,
malformed, or oversized snapshot is denied before it can be approved. Review
data is separate from the redacted outcome receipt.

## Receipt rules

- A `commandExecution` item with status `completed` and exit code `0` or `null`
  is recorded as a command receipt. A failed, canceled, unknown, or incomplete
  command remains unresolved because it may have produced partial effects.
- A `fileChange` item is recorded as applied only with status `completed`.
  Failed, canceled, unknown, and incomplete results remain unresolved.
- Explicit `declined` and `rejected` results clear the pending item. Cancellation
  is not treated as proof that nothing changed.
- Approval requests use `itemId`; the legacy command-approval form may use
  `callId`. An accepted approval without a matching start item creates a
  redacted pending placeholder. A missing identifier remains unresolved.
- Codex v2 `item/fileChange/requestApproval` has required `threadId`, `turnId`,
  and `itemId`, and optional `reason` / unstable `grantRoot`; it does not carry
  file contents. `item/fileChange/patchUpdated` carries the same three IDs and
  `changes` entries shaped as `{path, kind, diff}`. `kind` is the tagged enum
  `{type: "add"}`, `{type: "delete"}`, or
  `{type: "update", movePath?: string | null}`. Veasel rejects unknown tags,
  malformed enum values, and extra change fields. It reviews only a non-empty
  complete snapshot with required fields, at most 128 changes, and a serialized
  review no larger than 12,000 bytes. Snapshots are replaced or invalidated by
  later updates for the same exact identity; item correlation uses the raw
  `itemId` field and never its legacy `callId` fallback. A malformed update
  without enough identity to target one snapshot clears the active turn's
  cached snapshots when its provided identity does not conflict with that
  turn. Legacy `applyPatchApproval` remains a separate request shape and is not
  described by this v2 review contract.
- `mcpToolCall`, `dynamicToolCall`, `collabAgentToolCall`, `imageGeneration`,
  `functionCallOutput`, `subAgentActivity`, and extension items other than
  `clock.sleep` are outside Veasel's independently observed file/command
  receipt contract, so their presence leaves the turn uncertain. Known informational
  items (`userMessage`, `agentMessage`, `hookPrompt`, `plan`, `reasoning`,
  `webSearch`, `imageView`, review-mode markers, and context compaction) do not
  represent command or filesystem effects and are ignored for these receipts.
  The pinned app-server contract represents `clock.sleep` as an `Extension`
  item with kind `clock.sleep`; it is also ignored as a wait-only item.

These rules cover Codex CLI 0.172.0's inspected contract. Other installed
versions are handled conservatively: unknown item types, missing identifiers,
or unrecognized result data remain unresolved and must not be turned into a
claim that no effect occurred. An interrupted turn is surfaced as cancelled;
any already recorded effects remain in its outcome.

The approval and patch snapshot fields above are pinned to
`codex-rs/app-server-protocol/src/protocol/v2/item.rs`
(`FileChangePatchUpdatedNotification`, `FileUpdateChange`, and
`FileChangeRequestApprovalParams`) at the exact commit named above. The local
adapter's permission mapping remains ask = `approvalPolicy: on-request` plus
`sandbox: read-only`; it does not grant write access by enabling review.
