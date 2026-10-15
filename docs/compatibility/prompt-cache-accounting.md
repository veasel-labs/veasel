# Prompt-cache accounting and request markers — study pin

**OpenCode upstream:** [anomalyco/opencode](https://github.com/anomalyco/opencode)
**Pinned commit:** [`37df62f4a1b6d89187a1169187a6cef10557c0ca`](https://github.com/anomalyco/opencode/tree/37df62f4a1b6d89187a1169187a6cef10557c0ca)
**Primary source:** [`packages/core/src/session/usage.ts`](https://github.com/anomalyco/opencode/blob/37df62f4a1b6d89187a1169187a6cef10557c0ca/packages/core/src/session/usage.ts)
**License:** MIT

**Anthropic docs (field semantics + request markers):** [Prompt caching](https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching) (rechecked 2026-10-15)

**OpenAI docs (request-side cache knobs):** [Prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching) (rechecked 2026-10-15) — `prompt_cache_key` and `prompt_cache_retention` on Chat Completions and Responses; keys influence routing/accounting and do not guarantee hits.

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

Anthropic prompt caching is request-shaped: automatic top-level
`cache_control: {"type":"ephemeral"}` and/or explicit `cache_control` on
content blocks (system text, tools order, messages). Minimum token thresholds
still apply; short prompts may return zeros without error.

## What Veasel adapted

### Accounting (provider-reported)

| Provider shape | Veasel `cache_read_tokens` | Veasel `cache_creation_tokens` | Notes |
|---|---|---|---|
| OpenAI Chat Completions | `prompt_tokens_details.cached_tokens` | `0` (writes not reported) | Subset of `prompt_tokens`; do not add to input |
| OpenAI Responses | `input_tokens_details.cached_tokens` | `input_tokens_details.cache_write_tokens` when present | Subset of `input_tokens` |
| Anthropic Messages | `cache_read_input_tokens` | `cache_creation_input_tokens` | Disjoint from `input_tokens` |
| Gemini | `cachedContentTokenCount` | `0` | Subset of `promptTokenCount` |

`cache_reported` is true only when the adapter saw cache-related keys
(including explicit zeros). Omitted keys leave `cache_reported` false.
Capability `sessions.usage.prompt_cache` advertises this accounting only.

### Request-side Anthropic markers

For Anthropic Messages (default on), Veasel emits:

1. Top-level `cache_control: {"type":"ephemeral"}` (Anthropic automatic caching
   for growing conversation prefixes).
2. When a system prompt is present, a system text content block with the same
   `cache_control` (explicit breakpoint on the stable system prefix; helpful for
   gateways that honor block markers).

Control with `VEASEL_ANTHROPIC_PROMPT_CACHE`:

| Value | Behavior |
|---|---|
| unset / `auto` / other | Ephemeral 5-minute markers (default) |
| `1h` | Ephemeral markers with `"ttl":"1h"` |
| `off` / `0` / `false` / `no` | No `cache_control` fields |

Capability `provider.anthropic.prompt_cache` appears when request markers are
enabled. Fixture evidence: `provider_cache_test.v`.

### Request-side OpenAI knobs

For catalog providers `openai` (Chat Completions) and `openai-responses`
(Responses) only—not Meta Responses or generic openai-compatible gateways—
Veasel emits:

1. Top-level `prompt_cache_key` (default `veasel`; override with
   `VEASEL_OPENAI_PROMPT_CACHE_KEY`, max 64 UTF-8 bytes after trim).
2. Optional `prompt_cache_retention` when the mode requests it.

Control with `VEASEL_OPENAI_PROMPT_CACHE`:

| Value | Behavior |
|---|---|
| unset / `auto` / other | `prompt_cache_key` only; omit retention (provider org default) |
| `24h` | Key plus `prompt_cache_retention: "24h"` |
| `in_memory` / `in-memory` | Key plus `prompt_cache_retention: "in_memory"` |
| `off` / `0` / `false` / `no` | No cache request fields |

Capability `provider.openai.prompt_cache` appears when these knobs are enabled
(env not `off`). OpenAI automatic prefix caching can still apply without a key;
the key helps routing on pre–GPT-5.6 models and separate cache accounting.
GPT-5.6+ `prompt_cache_options` / explicit breakpoints are not implemented.
Fixture evidence: `provider_cache_test.v`.

### Request-side Gemini explicit cache

For catalog provider `gemini`, when `VEASEL_GEMINI_CACHED_CONTENT` is set to a
`cachedContents/...` resource name (bare ids are prefixed automatically) and
`VEASEL_GEMINI_PROMPT_CACHE` is not `off`, Veasel emits top-level
`cachedContent` on `streamGenerateContent` requests. Default mode is `auto`
(reference when named); `off` suppresses the field even if a name is set.

Capability `provider.gemini.prompt_cache` appears only when a resource name is
configured and not disabled. Veasel does **not** create or expire Gemini caches
on the assistant turn path. Explicit management helpers
`create_gemini_cached_content` (`POST .../cachedContents`) and
`expire_gemini_cached_content` (`DELETE .../cachedContents/{id}`) perform the
live HTTP calls against the configured Gemini base URL; fixture evidence is in
`provider_gemini_cache_test.v` (loopback HTTP server) plus the create-body
encoder in `provider_cache_test.v`. Hits remain provider-reported via
`cachedContentTokenCount` only.

No OpenCode source was copied. Veasel does **not** invent % savings or dollar
amounts from cache counters. Enabling request markers does not guarantee cache
hits; hits appear only when the provider reports cache usage fields.

## Residual gaps

| Gap | Status |
|---|---|
| Request-side Anthropic `cache_control` | Shipped (default auto; env opt-out) |
| OpenAI `prompt_cache_key` / `prompt_cache_retention` | Shipped for `openai` + `openai-responses` (default auto; env opt-out). Keys with C0/DEL fall back to `veasel`. Gemini `cachedContent` names reject all C0/DEL (not only NUL/CR/LF). |
| OpenAI GPT-5.6+ `prompt_cache_options` / breakpoints | Not implemented |
| Gemini explicit `cachedContent` reference on generateContent | Shipped when `VEASEL_GEMINI_CACHED_CONTENT` names a resource and `VEASEL_GEMINI_PROMPT_CACHE` is not `off`; create/expire are explicit helpers (not turn path), fixture-tested over loopback HTTP |
| Legacy Bedrock top-level `cache_control` rejection | Use block markers only if targeting that path; not separately tested here |
| Models.dev-priced USD cost | Still unavailable |
| Reasoning-token split | Shipped as provider-reported `reasoning_tokens` / `reasoning_reported` (OpenAI Chat `completion_tokens_details.reasoning_tokens`, OpenAI Responses `output_tokens_details.reasoning_tokens`, Gemini `thoughtsTokenCount`); persisted on operations and session usage; never invented when keys are absent |
| Claiming dollar savings without price pins | Forbidden |
