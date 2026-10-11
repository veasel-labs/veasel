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
| 1 | Session HTTP API and command runner | TUI ↔ loopback server ↔ OS process | S, I, E | AGNT05 | The server has no application token. It binds to `127.0.0.1`; it rejects non-loopback Host values and browser Origins, but requests without Origin are accepted. Workspace reads are bounded. File and shell approvals require a stored review transition before a one-time side effect. | A same-user process can call the API; a model can propose a malicious command and persuade a user to approve it. | Read session data, modify any files writable by the server user, access network services and inherited environment credentials. | Medium for untrusted same-user processes or prompt-injected proposals. | High | Keep loopback binding and Host/Origin checks. Show the exact command, cwd and timeout before approval; persist `running` before spawn; cap active commands, runtime and output; contain initial cwd in the workspace; never retry uncertain effects. Commands are intentionally not sandboxed and inherit the server environment. Revisit a random per-install bearer token before browser or remote clients are added. | Same-UID callers can invoke API approvals; shell commands can leave the workspace, access credentials and race filesystem checks. Human review is the execution gate, not an OS isolation boundary. | Commands cannot run before durable review and approval; rejected commands do not run; parent cwd traversal fails; run time and output are bounded; restart marks running commands uncertain and does not replay them; the UI discloses OS permissions and environment access. | `shell_commands.v`; `store.v`; `api.v`; `agent_runtime.v`; `tui/src/main.ts`; `scripts/api-smoke.sh`; `main_test.v`. | Implementation added; cross-platform CI review pending |
| 2 | Prompts, history, workspace content, and provider credentials | Backend ↔ external model provider | I | LLM06 | Session prompts, history, and requested workspace tool results are sent to the configured provider; keys are read from environment and sent in provider-specific headers. | User configures an external provider → session text and requested file excerpts are sent to that provider. A misconfigured or hostile endpoint could observe prompts and credentials. | Disclosure of selected workspace excerpts, private conversation text, or provider key. | Medium | High | Keep credentials server-side; require HTTPS except loopback HTTP; reject URL userinfo, query, fragments, and redirects; cap input/output; disclose provider data flow before the user sends a workspace request. | The configured provider receives user prompts, history, and excerpts returned by tools the model requests. | Provider smoke verifies exact auth header and tool-result flow for all adapters; redirects are disabled; the TUI discloses that read-tool excerpts go to the configured provider. | `provider.v`; `api.v`; `tui/src/main.ts`; `scripts/api-smoke.sh`. | bounded tool disclosure added |
| 3 | Repository content returned to an LLM | Agent ↔ workspace | T, E, I | AGNT02, AGNT04, AGNT05 | The bounded agent loop exposes workspace reads and an edit proposal tool. File contents and tool results are untrusted; proposals are never applied before explicit user approval. | Malicious instructions in a README, source comment, or generated file → model follows them → requests reads or proposes a malicious file change. | Source disclosure within the selected root or a user-approved harmful in-root file change. | Medium | High | Resolve paths beneath the canonical selected root, reject traversal and outside symlinks, cap each operation and the full tool loop, treat results as untrusted, require diff review and explicit approval, compare the reviewed snapshot at apply time, and do not expose shell tools. | Prompt injection can still request in-root disclosure; a user can approve a harmful in-root diff. POSIX replacement preserves permission bits but not ACLs or extended attributes. | Fixture provider attempts traversal and outside-root symlink reads; both fail; no write occurs before diff access and approval; shell execution remains unavailable; all provider families pass tool transcript smoke. | `workspace_edits.v`; `workspace_tools.v`; `agent_runtime.v`; `provider.v`; `scripts/api-smoke.sh`; `agent_runtime_test.v`; `main_test.v`; `README.md`. | bounded read tools and approved edit proposals added; CI validation pending |
| 4 | Synchronous completion route | API worker and provider resources | D | LLM04 | Requests permit 64 messages and 100 KB input, provider response reads stop at 1 MB, provider calls wait up to 60 seconds, and a process-wide semaphore caps in-flight requests. Client disconnects do not yet cancel queued or active provider work. | Local client starts many slow model calls → the semaphore bounds provider calls, while excess requests wait in Veb workers until a slot or request timeout is available. | Local API latency and resource exhaustion within the configured concurrency bound. | Low for normal single-user TUI use; medium under automated load. | Medium | Medium | Propagate request cancellation and deadlines through queued turns and provider transports; expose queue and active-call limits before background jobs or concurrent agents. | A disconnected client may leave a provider request consuming a slot until its timeout. | Stress check demonstrates a fixed upper bound on in-flight provider requests; cancellation releases its slot and socket. | `api.v:94-126`, `api.v:139-195`; `provider.v:389-410`; `main.v:12-16`. | concurrency cap added; cancellation pending |
| 5 | Veasel mascot artwork | Public product and website assets | T | — | The current pixel adaptation is marked CC BY-NC 4.0 in `THIRD_PARTY_NOTICES.md`; product instructions prohibit noncommercial mascot art. | Commercial distribution of the product includes the adaptation without separate rights. | Licensing conflict and inability to distribute commercially. | Medium if commercial release is pursued. | High | High | Keep the rights notice and obtain explicit commercial permission before commercial use; otherwise remove the artwork and use original, non-derivative identity assets. | Permission status is not evidenced in the repo. | Commercial release has a documented license grant or no CC BY-NC artwork is shipped. | `THIRD_PARTY_NOTICES.md`; `tui/README.md`; product `AGENTS.md`. | new |
| 6 | Agent Plugin files, skills, MCP servers | Plugin package ↔ V runtime / provider | T, E, I, D | AGNT02, AGNT04, AGNT05 | Agent Plugins v1 supports prompt instructions and MCP servers, including stdio child processes and remote HTTP endpoints. Veasel validates local packages and exposes explicitly trusted stdio and Streamable HTTP MCP tools. | Malicious or compromised plugin uses a symlink escape, instruction injection, executable, remote endpoint, header forwarding, or tool result to read/disclose data or trigger an unapproved side effect. | Workspace/provider secret disclosure, unauthorized file changes, arbitrary code execution as the Veasel user, or resource exhaustion. | Medium for installed third-party plugins. | Critical | High | Validate against locally pinned schemas; enforce filesystem-resolved package and workspace containment; isolate failure boundaries; treat instructions, allowed-tools, resources, schemas, descriptions and results as untrusted; use literal process argv; keep trust session-scoped; refuse HTTP redirects, verify HTTPS certificates, disable request retries, and cap MCP tools, output, frames and response time. Document that stdio subprocesses inherit the user's OS privileges unless an OS sandbox is active. | The portable standard does not provide sandboxing. A malicious approved executable can act with the runtime user's privileges, and MCP tools currently run without per-call approval. HTTP authorization is client-managed and does not have OAuth discovery/consent yet. | Conformance fixtures prove path and config rules; untrusted plugins cannot run until explicitly trusted; process/resource limits and shutdown are verified; tool effects, authorization and per-call approval remain open; redirects cannot leak headers. | Pinned v1.0.0 [`agent-plugins.md`](../compatibility/agent-plugins.md); V `vlib/mcp`, `vlib/net/http` and `vlib/os/process.v` inspected at `.v-version`. | experimental stdio and HTTP runtime added |

## Mitigations and security acceptance criteria

| Finding | Mitigation | Acceptance criteria | Owner | Verified |
|---|---|---|---|---|
| 1 | Keep server loopback-only and preserve request Host/Origin validation. Persist only a canonical existing directory as the per-session workspace boundary. | API tests reject non-loopback Host/Origin and nonexistent/non-directory roots; path tests reject `..`, absolute paths, and symlink escapes. | Veasel Code | Local V domain tests and API smoke pass on Linux; pinned Linux, macOS, and Windows CI verification is pending. |
| 2 | Keep keys in backend environment; validate provider endpoints; make outbound disclosure visible in the client before sending workspace excerpts. | Unit tests cover TLS/loopback rules, userinfo, query strings, fragments, unsupported schemes, malformed URLs, and normalized paths. Three-provider mock API smoke confirms provider headers, tool-result flow, redirect rejection, and TUI data-flow disclosure. | Veasel Code | Verified for endpoint validation and provider flow; endpoint unit tests and the API smoke pass in pinned Linux, macOS, and Windows CI. |
| 3 | Treat repository/tool text as untrusted; split tool permissions into read, write, and execute; persist exact reviews and approvals before side effects. | Three-provider smoke rejects parent traversal; workspace tests and API smoke reject outside-root symlinks. File proposals have no effect before diff review/approval. Shell proposals have no effect before exact command review/approval; output and duration are bounded; interruption is uncertain and not replayed. | Veasel Code | Local V tests, three-provider API smoke, line-ending/control-character review checks, and TUI typecheck pass; cross-platform CI is pending. |
| 4 | Add bounded concurrency and cancellation from API request through model call and job lifecycle. | Load and cancellation checks show bounded workers and no leaked active slots. | Veasel Code | Pending. |
| 5 | Obtain commercial permission or remove the CC BY-NC artwork. | License grant is recorded or artwork is absent from distributed assets. | Product owner | Pending. |
| 6 | Complete Agent Plugins v1.0.0 with local schema validation, plugin-root containment, untrusted-content boundaries, transport-safe MCP adapters, and explicit execution trust. | Conformance/adversarial fixtures pass; stdio process lifecycle, resource bounds, tool effects and approval flows are tested; HTTP redirect controls are verified. | Veasel Code | Partial: local validation, per-session stdio/HTTP trust, bounded transports and model-tool dispatch exist; official fixtures, authorization flow and per-call approval remain open. |

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
File edits and shell commands require per-proposal human approval. Shell execution runs with the OS user account and inherited environment and is not sandboxed; inspect each command's file, network, and credential effects before approval. Human security review remains required before broadening the experimental stdio MCP runtime.
