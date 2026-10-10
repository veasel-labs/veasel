# Veasel Code threat model

**Scope:** Local V backend, OpenTUI client, SQLite sessions, configured model
providers, and the proposed repository-tool boundary
**Date:** 2026-10-09
**Modeler:** Codex
**Architecture source:** `docs/IMPLEMENTATION_PLAN.md`, `api.v`, `provider.v`,
`store.v`, `main.v`, `tui/src/main.ts`
**Version:** `1db4b73`
**Previous model:** Initial

## Architecture overview

- **Assets:** provider credentials in backend environment; user prompts and
  model replies in SQLite; workspace source files; tool arguments and output;
  event history; session directory metadata.
- **Trust boundaries:** user ↔ TUI; TUI ↔ loopback HTTP API; V backend ↔ SQLite;
  V backend ↔ configured external model provider; future agent ↔ repository
  content and future tools.
- **Data flows:** TUI sends prompts over loopback HTTP; V validates the request,
  loads recent session history, sends it to the configured provider over HTTPS
  (or user-configured loopback HTTP), then transactionally stores the user and
  assistant turns and emits replayable event IDs. Read-only workspace list,
  read, and literal search routes are available, but the model cannot invoke
  them yet.
- **Actors:** local user, other processes under the same OS account, browser
  origins reaching loopback, configured model provider, and future repository
  content that may contain adversarial instructions.

## Risk-ranked findings

| # | Asset / Flow | Trust boundary | STRIDE | Agentic ID | Threat and evidence | Attack path | Impact | Likelihood | Severity | Confidence | Mitigation | Residual | Acceptance criteria | Evidence | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Session HTTP API | TUI ↔ loopback server | S, I, E | AGNT05 | The server has no application token. It binds to `127.0.0.1`; it rejects non-loopback Host values and non-loopback browser Origins, but requests without Origin are accepted. Workspace creation canonicalizes and checks the directory. Read-only file APIs expose selected workspace content to same-user local callers. | A local process under the same OS user calls session routes and reads that user's session and workspace files. | Read session data and source files under the selected workspace root. | Low outside the local account; medium for untrusted same-user processes. | Medium | High | Keep loopback binding and strict Host/Origin checks. Resolve all requested paths under the canonical workspace root, reject traversal and outside symlinks, never follow symlinks during listing/search, cap reads, and keep writes and execution unavailable until explicit approval exists. Revisit a random per-install bearer token if browser or remote clients are added. | Same-UID callers can use the API to read files within the session root. | No non-loopback bind; malicious Host and Origin are rejected; traversal and outside symlinks fail; listing/search/read limits are enforced; no write/execute route exists. | `workspace_tools.v`; `api.v`; `scripts/api-smoke.sh`; `workspace_tools_test.v`. | read-only workspace routes added |
| 2 | Prompts, history, and provider credentials | Backend ↔ external model provider | I | LLM06 | Session prompts and history are sent to the configured provider; keys are read from environment and sent in provider-specific headers. | User configures an external provider → session text is sent to that provider. A misconfigured or hostile endpoint could observe prompts and credentials. | Disclosure of source excerpts included in prompts, private conversation text, or provider key. | Medium | High | Keep credentials server-side; require HTTPS except loopback HTTP; reject URL userinfo, query, fragments, and redirects; cap input/output; show provider disclosure in UX before adding file-content tools. | The configured provider receives all prompt/history context needed to answer. | Provider smoke verifies exact auth header; redirects are disabled; remote endpoints require TLS; UI clearly identifies provider and warns before workspace content leaves the machine. | `provider.v:94-164`, `provider.v:384-410`, `api.v:139-195`. | new |
| 3 | Repository content returned to an LLM | Agent ↔ workspace | T, E, I | AGNT02, AGNT04, AGNT05 | Read-only workspace APIs exist but are not exposed to the model yet. When provider tools are added, file and tool output must be treated as untrusted prompt content, not policy. | Malicious instructions in a README, source comment, or generated file → model follows them → invokes a broader tool or discloses unrelated data. | Unauthorized file changes, command execution, or source disclosure. | Medium | High | Keep read tools scoped to the selected root; mark tool output as untrusted data; deny writes and shell by default; gate each side effect with a durable approval decision that includes the exact operation and arguments. | Prompt injection cannot be eliminated; it must not expand tool permissions. | Fixture repo containing injection text cannot cause reads outside root, writes, or shell without a matching approval. | `workspace_tools.v`; provider tool loop and approval flow remain unimplemented. | read APIs added; agent integration pending |
| 4 | Synchronous completion route | API worker and provider resources | D | LLM04 | Requests permit 64 messages and 100 KB input, provider response reads stop at 1 MB, provider calls wait up to 60 seconds, and a process-wide semaphore caps in-flight requests. Client disconnects do not yet cancel queued or active provider work. | Local client starts many slow model calls → the semaphore bounds provider calls, while excess requests wait in Veb workers until a slot or request timeout is available. | Local API latency and resource exhaustion within the configured concurrency bound. | Low for normal single-user TUI use; medium under automated load. | Medium | Medium | Propagate request cancellation and deadlines through queued turns and provider transports; expose queue and active-call limits before background jobs or concurrent agents. | A disconnected client may leave a provider request consuming a slot until its timeout. | Stress check demonstrates a fixed upper bound on in-flight provider requests; cancellation releases its slot and socket. | `api.v:94-126`, `api.v:139-195`; `provider.v:389-410`; `main.v:12-16`. | concurrency cap added; cancellation pending |
| 5 | Veasel mascot artwork | Public product and website assets | T | — | The current pixel adaptation is marked CC BY-NC 4.0 in `THIRD_PARTY_NOTICES.md`; product instructions prohibit noncommercial mascot art. | Commercial distribution of the product includes the adaptation without separate rights. | Licensing conflict and inability to distribute commercially. | Medium if commercial release is pursued. | High | High | Keep the rights notice and obtain explicit commercial permission before commercial use; otherwise remove the artwork and use original, non-derivative identity assets. | Permission status is not evidenced in the repo. | Commercial release has a documented license grant or no CC BY-NC artwork is shipped. | `THIRD_PARTY_NOTICES.md`; `tui/README.md`; product `AGENTS.md`. | new |
| 6 | Agent Plugin files, skills, MCP servers | Plugin package ↔ V runtime / provider | T, E, I, D | AGNT02, AGNT04, AGNT05 | Agent Plugins v1 supports prompt instructions and MCP servers, including stdio child processes and remote HTTP endpoints. Veasel has an experimental validation-only loader, but no executable plugin runtime or trust policy. | Malicious or compromised plugin uses a symlink escape, instruction injection, executable, remote endpoint, header forwarding, or tool result to read/disclose data or trigger an unapproved side effect. | Workspace/provider secret disclosure, unauthorized file changes, arbitrary code execution as the Veasel user, or resource exhaustion. | Medium for installed third-party plugins. | Critical | High | Validate against locally pinned schemas; enforce filesystem-resolved package and workspace containment; isolate failure boundaries; treat instructions, allowed-tools, resources and results as untrusted; intersect skill tool hints with user policy; use literal process argv; separate plugin trust from per-tool approval; never follow configured HTTP redirects with plugin headers; cap MCP tool output and resource use. Document that stdio subprocesses inherit the user's OS privileges unless an OS sandbox is active. | The portable standard does not provide sandboxing. A malicious approved executable can act with the runtime user's privileges. | Conformance fixtures prove path and config rules; untrusted plugins cannot run until explicitly trusted; denied tool actions have no effect; redirects cannot leak headers; process/resource limits and shutdown are verified. | Pinned v1.0.0 [`agent-plugins.md`](../compatibility/agent-plugins.md); V `vlib/mcp` and `vlib/os/process.v` inspected at `.v-version`. | new |

## Mitigations and security acceptance criteria

| Finding | Mitigation | Acceptance criteria | Owner | Verified |
|---|---|---|---|---|
| 1 | Keep server loopback-only and preserve request Host/Origin validation. Persist only a canonical existing directory as the per-session workspace boundary. | API tests reject non-loopback Host/Origin and nonexistent/non-directory roots; future path tests reject `..`, absolute paths, and symlink escapes. | Veasel Code | Root canonicalization implemented; focused V/API checks pending. |
| 2 | Keep keys in backend environment; validate provider endpoints; make outbound disclosure visible in the client before sending workspace excerpts. | Mock-provider API smoke confirms completion routing, provider headers, and redirect rejection. Dedicated endpoint-validation unit tests and client disclosure remain pending. | Veasel Code | Partially: API smoke passes; endpoint-validation unit tests and client disclosure pending. |
| 3 | Treat repository/tool text as untrusted; split tool permissions into read, write, and execute; persist exact approvals before side effects. | Prompt-injection fixture cannot cause an out-of-root read or a write/command without an exact approval record. | Veasel Code | Pending. |
| 4 | Add bounded concurrency and cancellation from API request through model call and job lifecycle. | Load and cancellation checks show bounded workers and no leaked active slots. | Veasel Code | Pending. |
| 5 | Obtain commercial permission or remove the CC BY-NC artwork. | License grant is recorded or artwork is absent from distributed assets. | Product owner | Pending. |
| 6 | Implement Agent Plugins v1.0.0 with local schema validation, plugin-root containment, untrusted-content boundaries, transport-safe MCP adapters, and explicit execution trust. | Conformance and adversarial fixtures pass; all child processes/resources close under verified limits; user-facing trust and approval flows are tested. | Veasel Code | Pending design and implementation. |

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
Human review remains required before the first write or shell tool is enabled.
