# Prompt-cache accounting — study pin

**OpenCode upstream:** [anomalyco/opencode](https://github.com/anomalyco/opencode)
**Pinned commit:** [`37df62f4a1b6d89187a1169187a6cef10557c0ca`](https://github.com/anomalyco/opencode/tree/37df62f4a1b6d89187a1169187a6cef10557c0ca)
**Primary source:** [`packages/core/src/session/usage.ts`](https://github.com/anomalyco/opencode/blob/37df62f4a1b6d89187a1169187a6cef10557c0ca/packages/core/src/session/usage.ts)
**License:** MIT

**Anthropic docs (field semantics):** [Prompt caching](https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching) (rechecked 2026-10-15)

**Study date:** 2026-10-15

## What was studied

OpenCode normalizes provider usage into `input`, `output`, `reasoning`, and
`cache.{read,write}` before multiplying by Models.dev price tiers. Veasel still
refuses cost without a pinned authoritative price schedule. The useful contract
is the field mapping and the distinction between providers that report cache
counters as a **subset** of prompt/input tokens (OpenAI Chat Completions
`prompt_tokens_details.cached_tokens`, OpenAI Responses
`input_tokens_details.cached_tokens` / optional `cache_write_tokens`, Gemini
`usageMetadata.cachedContentTokenCount`) versus Anthropic’s **disjoint**
`input_tokens` + `cache_read_input_tokens` + `cache_creation_input_tokens`.

## What Veasel adapted (field mapping only)

| Provider shape | Veasel `cache_read_tokens` | Veasel `cache_creation_tokens` | Notes |
|---|---|---|---|
| OpenAI Chat Completions | `prompt_tokens_details.cached_tokens` | `0` (writes not reported) | Subset of `prompt_tokens`; do not add to input |
| OpenAI Responses | `input_tokens_details.cached_tokens` | `input_tokens_details.cache_write_tokens` when present | Subset of `input_tokens` |
| Anthropic Messages | `cache_read_input_tokens` | `cache_creation_input_tokens` | Disjoint from `input_tokens` |
| Gemini | `cachedContentTokenCount` | `0` | Subset of `promptTokenCount` |

`cache_reported` is true only when the adapter saw cache-related keys
(including explicit zeros). Omitted keys leave `cache_reported` false.

No OpenCode source was copied. Veasel does **not** enable Anthropic
`cache_control` breakpoints or other request-side cache headers in this slice,
and does not invent % savings or dollar amounts from cache counters.

## Residual gaps

| Gap | Status |
|---|---|
| Request-side cache breakpoints / headers | Not implemented; accounting-only |
| Models.dev-priced USD cost | Still unavailable |
| Reasoning-token split | Not surfaced yet |
| Claiming “caching works” without request evidence | Forbidden |
