# Veasel Code threat model

**Scope:** Local V backend, OpenTUI client, SQLite sessions, configured model
providers, and the proposed repository-tool boundary
**Date:** 2026-10-10
**Modeler:** Codex
**Architecture source:** `docs/IMPLEMENTATION_PLAN.md`, `api.v`, `provider.v`,
`store.v`, `workspace_edits.v`, `main.v`, `tui/src/main.ts`
**Version:** unreleased branch
**Previous model:** Initial

## Architecture overview

- **Assets:** provider credentials in backend environment; user prompts and
  model replies in SQLite; workspace source files; tool arguments and output;
  event history; session directory metadata.
- **Trust boundaries:** user ↔ TUI; TUI ↔ loopback HTTP API; V backend ↔ SQLite;
  V backend ↔ configured external model provider; future agent ↔ repository
  content and future tools.
- **Data flows:** TUI sends prompts and explicit edit approvals over loopback HTTP; V validates the request,
  loads recent session history, sends it to the configured provider over HTTPS
  (or user-configured loopback HTTP), then transactionally stores the user and
  assistant turns and emits replayable event IDs. The session agent may call bounded workspace list, read, literal search, and
  file-edit proposal tools; requested file excerpts and tool results are sent
  to the configured provider. Proposed file contents remain in SQLite until a
  user reviews the diff and explicitly approves the session-scoped operation.
- **Actors:** local user, other processes under the same OS account, browser
  origins reaching loopback, configured model provider, and future repository
  content that may contain adversarial instructions.

## Risk-ranked findings

| # | Asset / Flow | Trust boundary | STRIDE | Agentic ID | Threat and evidence | Attack path | Impact | Likelihood | Severity | Confidence | Mitigation | Residual | Acceptance criteria | Evidence | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Session HTTP API | TUI ↔ loopback server | S, I, E | AGNT05 | The server has no application token. It binds to `127.0.0.1`; it rejects non-loopback Host values and non-loopback browser Origins, but requests without Origin are accepted. Workspace creation canonicalizes and checks the directory. Workspace reads are bounded; approval requires a persisted record that the proposal diff was opened, followed by a one-time apply transition. | A local process under the same OS user calls session routes and reads that user's session and workspace files. | Read session data and source files under the selected workspace root. | Low outside the local account; medium for untrusted same-user processes. | Medium | High | Keep loopback binding and strict Host/Origin checks. Resolve all requested paths under the canonical workspace root, reject traversal and outside symlinks, never follow symlinks during listing/search, cap reads, require durable diff access and one-time file approval, and keep shell execution unavailable. Revisit a random per-install bearer token if browser or remote clients are added. | Same-UID callers can access the diff route and invoke approval; path checks cannot sandbox a same-user process racing the filesystem. | No non-loopback bind; malicious Host and Origin are rejected; traversal and outside symlinks fail; listing/search/read limits are enforced; approval before diff access fails; proposals do not change disk; stale and symlink targets fail; interrupted writes are never replayed; shell execution is unavailable. | `workspace_edits.v`; `store.v`; `api.v`; `tui/src/main.ts`; `scripts/api-smoke.sh`; `workspace_tools_test.v`; `main_test.v`. | Diff-access gate and approval implementation under CI validation |
| 2 | Prompts, history, workspace content, and provider credentials | Backend ↔ external model provider | I | LLM06 | Session prompts, history, and requested workspace tool results are sent to the configured provider; keys are read from environment and sent in provider-specific headers. | User configures an external provider → session text and requested file excerpts are sent to that provider. A misconfigured or hostile endpoint could observe prompts and credentials. | Disclosure of selected workspace excerpts, private conversation text, or provider key. | Medium | High | Keep credentials server-side; require HTTPS except loopback HTTP; reject URL userinfo, query, fragments, and redirects; cap input/output; disclose provider data flow before the user sends a workspace request. | The configured provider receives user prompts, history, and excerpts returned by tools the model requests. | Provider smoke verifies exact auth header and tool-result flow for all adapters; redirects are disabled; the TUI discloses that read-tool excerpts go to the configured provider. | `provider.v`; `api.v`; `tui/src/main.ts`; `scripts/api-smoke.sh`. | bounded tool disclosure added |
| 3 | Repository content returned to an LLM | Agent ↔ workspace | T, E, I | AGNT02, AGNT04, AGNT05 | The bounded agent loop exposes workspace reads and an edit proposal tool. File contents and tool results are untrusted; proposals are never applied before explicit user approval. | Malicious instructions in a README, source comment, or generated file → model follows them → requests reads or proposes a malicious file change. | Source disclosure within the selected root or a user-approved harmful in-root file change. | Medium | High | Resolve paths beneath the canonical selected root, reject traversal and outside symlinks, cap each operation and the full tool loop, treat results as untrusted, require diff review and explicit approval, compare the reviewed snapshot at apply time, and do not expose shell tools. | Prompt injection can still request in-root disclosure; a user can approve a harmful in-root diff. POSIX replacement preserves permission bits but not ACLs or extended attributes. | Fixture provider attempts traversal and outside-root symlink reads; both fail; no write occurs before diff access and approval; shell execution remains unavailable; all provider families pass tool transcript smoke. | `workspace_edits.v`; `workspace_tools.v`; `agent_runtime.v`; `provider.v`; `scripts/api-smoke.sh`; `agent_runtime_test.v`; `main_test.v`; `README.md`. | bounded read tools and approved edit proposals added; CI validation pending |
| 4 | Synchronous completion route | API worker and provider resources | D | LLM04 | Requests permit 64 messages and 100 KB input, provider response reads stop at 1 MB, provider calls wait up to 60 seconds, and a process-wide semaphore caps in-flight requests. Client disconnects do not yet cancel queued or active provider work. | Local client starts many slow model calls → the semaphore bounds provider calls, while excess requests wait in Veb workers until a slot or request timeout is available. | Local API latency and resource exhaustion within the configured concurrency bound. | Low for normal single-user TUI use; medium under automated load. | Medium | Medium | Propagate request cancellation and deadlines through queued turns and provider transports; expose queue and active-call limits before background jobs or concurrent agents. | A disconnected client may leave a provider request consuming a slot until its timeout. | Stress check demonstrates a fixed upper bound on in-flight provider requests; cancellation releases its slot and socket. | `api.v:94-126`, `api.v:139-195`; `provider.v:389-410`; `main.v:12-16`. | concurrency cap added; cancellation pending |
| 5 | Veasel mascot artwork | Public product and website assets | T | — | The current pixel adaptation is marked CC BY-NC 4.0 in `THIRD_PARTY_NOTICES.md`; product instructions prohibit noncommercial mascot art. | Commercial distribution of the product includes the adaptation without separate rights. | Licensing conflict and inability to distribute commercially. | Medium if commercial release is pursued. | High | High | Keep the rights notice and obtain explicit commercial permission before commercial use; otherwise remove the artwork and use original, non-derivative identity assets. | Permission status is not evidenced in the repo. | Commercial release has a documented license grant or no CC BY-NC artwork is shipped. | `THIRD_PARTY_NOTICES.md`; `tui/README.md`; product `AGENTS.md`. | new |
| 6 | Agent Plugin files, skills, MCP servers | Plugin package ↔ V runtime / provider | T, E, I, D | AGNT02, AGNT04, AGNT05 | Agent Plugins v1 supports prompt instructions and MCP servers, including stdio child processes and remote HTTP endpoints. Veasel validates local packages and exposes explicitly trusted stdio MCP tools; Streamable HTTP is metadata-only. | Malicious or compromised plugin uses a symlink escape, instruction injection, executable, remote endpoint, header forwarding, or tool result to read/disclose data or trigger an unapproved side effect. | Workspace/provider secret disclosure, unauthorized file changes, arbitrary code execution as the Veasel user, or resource exhaustion. | Medium for installed third-party plugins. | Critical | High | Validate against locally pinned schemas; enforce filesystem-resolved package and workspace containment; isolate failure boundaries; treat instructions, allowed-tools, resources, schemas, descriptions and results as untrusted; use literal process argv; keep trust session-scoped; never follow configured HTTP redirects with plugin headers; cap MCP tools, output, frames and response time. Document that stdio subprocesses inherit the user's OS privileges unless an OS sandbox is active. | The portable standard does not provide sandboxing. A malicious approved executable can act with the runtime user's privileges, and MCP tools currently run without per-call approval. | Conformance fixtures prove path and config rules; untrusted plugins cannot run until explicitly trusted; process/resource limits and shutdown are verified; tool effects and per-call approval remain open; redirects cannot leak headers. | Pinned v1.0.0 [`agent-plugins.md`](../compatibility/agent-plugins.md); V `vlib/mcp` and `vlib/os/process.v` inspected at `.v-version`. | experimental stdio runtime added |

## Mitigations and security acceptance criteria

| Finding | Mitigation | Acceptance criteria | Owner | Verified |
|---|---|---|---|---|
| 1 | Keep server loopback-only and preserve request Host/Origin validation. Persist only a canonical existing directory as the per-session workspace boundary. | API tests reject non-loopback Host/Origin and nonexistent/non-directory roots; path tests reject `..`, absolute paths, and symlink escapes. | Veasel Code | Local V domain tests and API smoke pass on Linux; pinned Linux, macOS, and Windows CI verification is pending. |
| 2 | Keep keys in backend environment; validate provider endpoints; make outbound disclosure visible in the client before sending workspace excerpts. | Unit tests cover TLS/loopback rules, userinfo, query strings, fragments, unsupported schemes, malformed URLs, and normalized paths. Three-provider mock API smoke confirms provider headers, tool-result flow, redirect rejection, and TUI data-flow disclosure. | Veasel Code | Verified for endpoint validation and provider flow; endpoint unit tests and the API smoke pass in pinned Linux, macOS, and Windows CI. |
| 3 | Treat repository/tool text as untrusted; split tool permissions into read, write, and execute; persist diff access and exact approvals before side effects. | Three-provider smoke rejects parent traversal; workspace tests and API smoke reject outside-root symlinks. Proposals have no effect before diff access and approval; hidden terminal controls and line-ending-only changes are covered by review rules and tests; no shell command tool is exposed. | Veasel Code | Local V tests, three-provider API smoke, line-ending/control-character review checks, and TUI typecheck pass; cross-platform CI is pending. Shell remains unavailable. |
| 4 | Add bounded concurrency and cancellation from API request through model call and job lifecycle. | Load and cancellation checks show bounded workers and no leaked active slots. | Veasel Code | Pending. |
| 5 | Obtain commercial permission or remove the CC BY-NC artwork. | License grant is recorded or artwork is absent from distributed assets. | Product owner | Pending. |
| 6 | Complete Agent Plugins v1.0.0 with local schema validation, plugin-root containment, untrusted-content boundaries, transport-safe MCP adapters, and explicit execution trust. | Conformance/adversarial fixtures pass; stdio process lifecycle, resource bounds, tool effects and approval flows are tested; HTTP redirect controls are verified. | Veasel Code | Partial: local validation, per-session stdio trust, bounded process transport and model-tool dispatch exist; HTTP and per-call approval remain open. |

## Attack paths

1. Same-user local process → loopback API without Origin → session data access.
2. User session → configured external provider → prompt/history disclosure.
3. Future malicious repository text → model/tool loop → attempted permission
   expansion; exact tool scopes and explicit approvals must stop side effects.
4. Slow model endpoint → synchronous Veb route → worker saturation; add
   bounded concurrency and cancellation before multi-agent execution.
5. CC BY-NC artwork → commercial package → licensing conflict; resolve before
   commercialization.
6. Plugin package → MCP stdio or remote transport → tool result/model loop;
   package validation, trust, exact permissions and resource bounds must stop
   the package from widening runtime authority.

## Incremental review

- **Unchanged:** none; this is the initial model.
- **New:** canonical workspace root validation; local API boundary, provider disclosure, future repository prompt
  injection, synchronous request exhaustion, mascot licensing.
- **Next review:** update as repository tools, Agent Plugin runtime integration,
  MCP connectors, write tools, shell execution, remote APIs, or background jobs
  are added.

## Review status

This is an evidence-linked engineering model, not a security certification.
File edits require per-proposal human approval. Human security review remains required before shell execution or broadening the experimental stdio MCP runtime.
