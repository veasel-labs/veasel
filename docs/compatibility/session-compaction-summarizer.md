# Session compaction summarizer — study pin

**OpenCode upstream:** [anomalyco/opencode](https://github.com/anomalyco/opencode)
**Pinned commit:** [`37df62f4a1b6d89187a1169187a6cef10557c0ca`](https://github.com/anomalyco/opencode/tree/37df62f4a1b6d89187a1169187a6cef10557c0ca)
**Primary source:** [`packages/core/src/session/compaction.ts`](https://github.com/anomalyco/opencode/blob/37df62f4a1b6d89187a1169187a6cef10557c0ca/packages/core/src/session/compaction.ts)
**License:** MIT

**Pi upstream:** [earendil-works/pi](https://github.com/earendil-works/pi)
**Pinned commit:** [`b06c1f2cf1dea6af8748ddeee18c23587d2cb7c6`](https://github.com/earendil-works/pi/tree/b06c1f2cf1dea6af8748ddeee18c23587d2cb7c6)
**Primary source:** [`packages/coding-agent/src/core/compaction/compaction.ts`](https://github.com/earendil-works/pi/blob/b06c1f2cf1dea6af8748ddeee18c23587d2cb7c6/packages/coding-agent/src/core/compaction/compaction.ts)
**License:** Apache-2.0

**Study date:** 2026-10-15

## What was studied

OpenCode triggers compaction from estimated context versus a model ceiling, keeps
a recent token window, and may summarize via an LLM or native provider
compaction path. Pi treats compaction as a separate conversation task that cuts
on measured context tokens, keeps recent turns, and appends a summary entry
without deleting raw durable history.

## What Veasel adapted (principles only)

Veasel keeps its existing extractive in-flight compaction and adds an **optional**
summarizer selected by `VEASEL_SESSION_COMPACTION_SUMMARIZER`:

| Mode | Behavior |
|---|---|
| `extractive` (default) | Untrusted line excerpts; no provider call. |
| `native` | Structured local summary (goals / tools / path-like tokens); no provider call. |
| `llm` | One no-tools provider completion over the bounded extractive digest; records provider usage only when the adapter sets `usage.reported`. |

Shared product rules:

- Summaries stay wrapped as untrusted context.
- Durable SQLite chat rows are not deleted or rewritten.
- If the summarizer errors, returns empty text, or would grow measured UTF-8
  payload (or fail message-count relief), Veasel falls back to extractive and
  records `*_fallback_extractive` on `session.compaction`.
- Size claims use measured UTF-8 bytes plus a conservative bytes/4 bound; cost
  and percent savings are never invented.

Capability `session.compaction.summarizer` is advertised only when mode is
`native` or `llm`.

## What was not copied

No OpenCode or Pi TypeScript source, prompt templates, token estimators, or
provider-native compaction protocol clients were copied. Provider-native
compaction APIs remain out of scope for this slice.
