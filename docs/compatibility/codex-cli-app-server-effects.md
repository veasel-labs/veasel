# Codex app-server effect receipts

**Inspected upstream:** [`openai/codex` `rust-v0.172.0`](https://github.com/openai/codex/tree/3d86e43b075adeba2193ec5c22ac92f55afd82e6)  
**Exact commit:** `3d86e43b075adeba2193ec5c22ac92f55afd82e6`

Veasel consumes the installed Codex CLI's app-server JSON-RPC lifecycle; no
Codex implementation code is copied. `item/started` and `item/completed` carry
the `commandExecution`, `fileChange`, and provider-tool item records. The
adapter reduces those records into redacted turn facts and never stores
command arguments, command output, file paths, or patch contents.

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
- `mcpToolCall`, `dynamicToolCall`, `collabAgentToolCall`, and
  `imageGeneration` are outside Veasel's independently observed file/command
  receipt contract, so their presence leaves the turn uncertain.

These rules cover Codex CLI 0.172.0's inspected contract. Other installed
versions are handled conservatively: missing or unrecognized result data must
not be turned into a claim that no effect occurred.
