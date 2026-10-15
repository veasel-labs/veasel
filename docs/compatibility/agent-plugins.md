# Agent Plugins v1.0.0 conformance plan

**Normative release:** Agent Plugins 1.0.0, tag commit
[`bd383552095128f6effe895b9257cfd580a6d179`](https://github.com/agentplugins/agent-plugins-spec/tree/bd383552095128f6effe895b9257cfd580a6d179)
**Release date:** 2026-09-28
**Agent Skills source:** [official Skills specification](https://github.com/agentskills/agentskills/blob/69ef37e9424c0a7ea9dd2293b559e43ec8176379/docs/specification.mdx)
at commit `69ef37e9424c0a7ea9dd2293b559e43ec8176379`.
The specification is normative; the upstream
[`skills-ref` validator](https://github.com/agentskills/agentskills/blob/69ef37e9424c0a7ea9dd2293b559e43ec8176379/skills-ref/src/skills_ref/validator.py)
is a secondary comparison source and describes itself as a demonstration
library, not a production dependency.
**MCP protocol revision:** [2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28)
**Veasel status:** experimental local discovery, per-session Skills activation,
and per-session trusted MCP stdio and Streamable HTTP tools are implemented.
The full Agent Plugins v1.0.0 conformance gate remains open.

The pinned upstream repository publishes the v1.0.0 specification and JSON
schemas, but no conformance fixture suite. Veasel's fixture corpus must
therefore be authored from the normative requirements and schema edge cases;
the pinned upstream tree was inspected on 2026-10-11.

`tests/agent_plugins/v1.0.0/` contains locally authored manifest, MCP document,
and Agent Skills frontmatter cases derived from the pinned normative release
and schema hashes below. No upstream fixture data or implementation code is
vendored. The corpus runs from `plugins_test.v` on Linux and Windows CI.
This adds repeatable spec-derived evidence; it is not an independent
cross-implementation suite and does not close the full conformance gate.

| Upstream schema at pinned commit | SHA-256 |
|---|---|
| [`plugin.schema.json`](https://github.com/agentplugins/agent-plugins-spec/blob/bd383552095128f6effe895b9257cfd580a6d179/schemas/1.0.0/plugin.schema.json) | `0a4aad95ce337878ad38802ebf0daa3fde76abe3f65400c86bcbb1ec0b3ab883` |
| [`mcp.schema.json`](https://github.com/agentplugins/agent-plugins-spec/blob/bd383552095128f6effe895b9257cfd580a6d179/schemas/1.0.0/mcp.schema.json) | `6539175bfcdf43085855183e86da40ea94b166547a72b47ae9a0a390516d3acb` |

The v1 portable package contains a root `plugin.json` and optional components
in the fixed `skills/` and `mcp.json` locations. Plugin directory installation,
updates, permissions, sandboxing, skill presentation, and Veasel-specific
extensions are client behavior outside the portable format. Veasel owns the
namespace `com.veasel.code` and currently reads one optional `display_name`
string (1–64 bytes after trimming, no ASCII controls) plus the presence of a same-named
directory at the package root. Other namespaces are ignored without
validation. Files inside `com.veasel.code` are not listed, read, or executed,
and catalog responses do not include filesystem paths. Conformance claims apply
to the pinned 1.0.0 release only; draft 1.1.0 is not treated as a released
contract.

The pinned normative document is the source of truth for the rules below. The
official schemas are
[`plugin.schema.json`](https://github.com/agentplugins/agent-plugins-spec/blob/bd383552095128f6effe895b9257cfd580a6d179/schemas/1.0.0/plugin.schema.json)
and
[`mcp.schema.json`](https://github.com/agentplugins/agent-plugins-spec/blob/bd383552095128f6effe895b9257cfd580a6d179/schemas/1.0.0/mcp.schema.json).
Runtime loading must validate locally and must not fetch schemas from the
network.

The validation loader applies bounded local resource limits: 1 MB per manifest,
MCP document, or skill file; 64 KB of YAML frontmatter; 256 immediate `skills/`
entries; 128 MCP servers and headers; 256 environment variables; and 4,096
arguments per stdio server. These are client safeguards, not additional
portable-format requirements, and will be exercised in tests.

## Conformance matrix

| Requirement | v1.0.0 behavior | Veasel status | Evidence required to close |
|---|---|---|---|
| Package boundary | Load from one directory; resolve every package path and reject symlink/junction escapes. | Symlink containment is verified on Linux and Windows CI, including accepted in-root links and rejected outside links. Windows junction (reparse-point) escapes are rejected by `plugins_test.v:test_plugin_paths_reject_windows_junction_escape` on Windows CI. | `plugins_test.v:test_plugin_paths_reject_traversal`; Linux and Windows run this test in `.github/workflows/ci.yml`. Add a Windows junction fixture and keep other platform-specific path cases open. |
| Manifest first | Read root `plugin.json` before component discovery; select a locally supported schema from canonical `$schema`. | Verified for local Agent Plugins v1.0.0 schema selection and fatal manifest ordering. | `plugins_test.v`: missing/unsupported schema, malformed JSON, and `test_agent_plugin_manifest_failure_prevents_component_discovery`. Loader uses a local schema constant and does not fetch schema URLs. |
| Closed manifest | Permit only the defined root fields. Required non-empty `$schema` and `name`; name grammar/length; metadata and author types. | Verified for the locally implemented v1.0.0 fields and name rules; locally authored fixtures now run on Linux and Windows. | `tests/agent_plugins/v1.0.0/plugin-manifests.json` and `plugins_test.v`; the same file covers manifest-first failure before Skill discovery. Independent cross-implementation fixtures remain open; upstream provides no fixture suite at the pinned revision. |
| Non-fatal manifest cases | Report and ignore unknown root fields; report and ignore a non-object `extensions`; ignore unsupported namespaces without validating their values. Other schema violations reject the whole plugin. | Verified for unknown root fields, non-object `extensions`, and opaque unknown namespace values. | `plugin-manifests.json` covers unknown root fields, wrong-type extensions, and opaque namespaces; `plugins_test.v:test_agent_plugin_manifest_enforces_closed_schema_and_nonfatal_exceptions` covers diagnostic details. Client-owned `com.veasel.code` semantics and independent cross-implementation fixtures remain open. |
| Fixed discovery | Missing locations are valid. Discover only immediate `skills/<child>/SKILL.md` and root `mcp.json`; validate expected filesystem kinds. | Verified for absent locations, immediate Skill discovery, nested decoys, invalid component filesystem kinds, symlink containment on Linux and Windows CI, and Windows junction escape rejection. | `plugins_test.v`: `test_agent_plugin_loads_manifest_and_shallow_skills`, `test_agent_plugin_component_discovery_is_optional_and_isolated`, `test_plugin_paths_reject_traversal`, and `test_plugin_paths_reject_windows_junction_escape`; Linux and Windows run the applicable cases in `.github/workflows/ci.yml`. |
| Agent Skills | Validate YAML frontmatter and required/optional fields per Agent Skills; require name to match parent directory; skip invalid skill alone; preserve optional files and directories; load referenced resources on demand. | Required/optional field types, supported field set, name grammar, length limits, and name/directory match are validated; Unicode lowercase letters/numbers are accepted. Discovered Skills expose `agent_skill_load` so the model can fetch an instruction body without session enablement, then `agent_skill_read_resource` for bounded UTF-8, read-only paths scoped to that Skill directory for session-enabled or turn-loaded Skills. Traversal and symlink escapes fail closed. Binary resources are rejected; scripts are readable as data but never executed automatically. Experimental `allowed-tools` is enforced as an exact-name restriction over the union of active Skill allowlists and the session's existing tools; disabled calls are rejected at runtime. File and shell approval and MCP trust remain independent. Full fixture matrix remains open. | `tests/agent_plugins/v1.0.0/skill-frontmatter.json` adds locally authored pinned frontmatter cases in `plugins_test.v`; `plugins_test.v:test_agent_skill_resource_reader_is_bounded_utf8_and_confined_to_skill_root` and `test_agent_plugin_skips_invalid_skill_and_keeps_valid_sibling`; `agent_runtime_test.v:test_agent_skill_resource_tool_reads_only_resources_from_enabled_skills` and `test_agent_skill_load_tool_loads_body_without_session_enable`; `scripts/api-smoke.sh` and `scripts/mock-provider.py` exercise resource discovery and reads through all four provider adapters. Independent cross-implementation fixtures and full Skills coverage remain open. Evidence for OpenCode-style on-demand load: anomalyco/opencode `packages/core/src/tool/plugin/skill.ts` at `37df62f4a1b6d89187a1169187a6cef10557c0ca`. |
| MCP document | Read only root `mcp.json`; validate canonical schema version equals `plugin.json`; closed top-level fields and independent server entries. | Locally verified for missing/unsupported schema, manifest/schema mismatch, required and typed `mcpServers`, unknown top-level fields, server-entry isolation, valid stdio and Streamable HTTP variants, invalid required/optional fields, and skipping optional unsupported SSE. This is targeted schema-derived behavior evidence, not full conformance. | `tests/agent_plugins/v1.0.0/mcp-documents.json` adds local document/entry-isolation cases in `plugins_test.v`; that file also covers transport variants and additional invalid fields. Both Linux and Windows CI run the corpus. Transport runtime fixture cases and independent cross-implementation evidence remain open; see the other MCP rows. |
| MCP transports | Support stdio and Streamable HTTP; also evaluate optional legacy HTTP+SSE. Use declared transport without silent fallback. | Stdio uses the `vlib/mcp` 2025-11-25 handshake. Streamable HTTP starts with `vlib/mcp` 2026-07-28 stateless discovery and request metadata, and falls back when a server reports an older supported revision. The Veasel adapter over `vlib/net/http` refuses redirects/retries, validates TLS, bounds responses, and preserves JSON-RPC protocol errors for negotiation. A 401 authorization failure disables only its trusted server while another server remains available; 401 responses parse `WWW-Authenticate` Bearer challenges (realm/scope/error/`resource_metadata`) and best-effort fetch RFC 9728 protected-resource metadata plus the first authorization server's RFC 8414 metadata (`issuer`, authorize/token/registration endpoints, PKCE methods) without forwarding configured MCP headers or performing an authorization-code dance. On turn cancel, stdio and Streamable HTTP transports emit best-effort `notifications/cancelled` for the in-flight request id; HTTP aborts via `on_progress_body` once bytes arrive. Legacy HTTP+SSE remains unsupported. | `plugin_mcp_http_transport_test.v` covers stateless discovery, request headers, downgrade to 2025-11-25, JSON and SSE responses, tools/list, tools/call, configured headers, redirect refusal, and 401 isolation. `mcp_oauth_test.v` covers Bearer/`resource_metadata` parsing. `plugin_mcp_cancel_test.v` covers cancelled notification encoding and cancel flags. `listen_notifications` covers GET SSE notification streams (405/404 = unsupported) into a dedicated notifications queue (not RPC pending). Trusted HTTP connects best-effort listen after initialize. Authorization-code + PKCE S256 (`mcp_oauth_flow.v`), token exchange into owner-only pending state plus named credentials (`mcp_oauth_tokens.v`), `POST /v1/mcp-oauth/authorize|complete` (`mcp.oauth`), a single-shot `127.0.0.1` loopback callback listener (`mcp_oauth_listener.v`), and headless `veasel mcp oauth authorize|complete` (optional `--listen`) are shipped. True HTTP TTFB cancel before any progress callback remains limited by `net.http`. |
| MCP stdio config | One executable token; bare name or contained `./` package path; no expansion in command; default cwd is plugin root; strict cwd roots and containment. | Implemented for direct process launch without a shell; bounded stdio framing/response time and paginated tool discovery. Limits are 16 pages per server and 64 tools per session; further pages are logged and omitted. | `plugin_mcp_transport_test.v` covers initialize, two tool-list pages, same-turn state, environment/cwd and shutdown on CI; malformed frames fail initialize, oversized frames fail receive at the frame limit, and a silent server fails receive at a bounded timeout. |
| MCP variables and environment | Set absolute `PLUGIN_ROOT` and persistent per-install `PLUGIN_DATA`; expand exact placeholders once in args/env/cwd only; reserved env names invalid; secrets are not portable. | Implemented for stdio with a sanitized platform environment and per-plugin persistent data directory. POSIX data permissions are restricted to `0700`. | `plugin_mcp_transport_test.v:test_plugin_mcp_data_persists_across_processes_and_environment_is_filtered` verifies root/data variables, one-pass placeholder expansion in args/env/cwd, inherited-secret filtering, POSIX permissions, and persistence across fresh server processes on Linux and Windows CI. Replacing files inside the package directory leaves `PLUGIN_DATA` in place. Configured environment names replace case variants on Windows. Other Windows environment-name cases remain open. |
| MCP HTTP config | Absolute HTTP(S) URL; no userinfo/fragment; HTTPS off-loopback; literal validated headers; reject case-insensitive duplicates; no redirects forwarding configured headers across origins. | URL/header validation is active. Catalog exposes only the parsed origin, never path/query values. Redirects are refused, TLS verification is enabled for HTTPS, and retries are disabled to avoid repeating tool side effects. A 401 response is isolated to its server and surfaces parsed Bearer challenge fields plus fetched protected-resource metadata when `resource_metadata` is absolute HTTPS or loopback HTTP without userinfo/fragment. Named HTTP credential sets are stored via `/v1/mcp-credentials` (`mcp.credentials`, `$VEASEL_DATA_DIR/mcp-credentials.json`); configured Streamable HTTP servers may reference a credential by name and merge headers at connect/trust time (literal headers win). OAuth authorize/complete + loopback listener + headless `veasel mcp oauth` are shipped. | `plugins_mcp_url_test.v` covers HTTPS/loopback accept and userinfo/fragment/cleartext-remote reject; `tests/agent_plugins/v1.0.0/mcp-documents.json` adds skip cases for userinfo, fragment, cleartext remote, and case-insensitive duplicate headers; `mcp_credentials_test.v`; `mcp_oauth_test.v`; `plugin_mcp_http_transport_test.v` bearer-isolation case. Cross-origin redirect refusal under live TLS mismatch and proxy behavior remain open. |
| Failure isolation | Invalid MCP config disables only MCP; invalid entries/unsupported transports/connection failures skip that server; independent skills still load. | Verified for component/config isolation; trusted stdio and HTTP connection, initialization, tool-list, and HTTP authorization failures skip that server while an independent trusted server still loads. | `plugins_test.v`: `test_agent_plugin_component_discovery_is_optional_and_isolated` and `test_agent_plugin_mcp_config_isolated_and_transport_bounded`; `plugin_mcp_http_transport_test.v:test_plugin_mcp_streamable_http_stateless_discovery_sse_tool_call_and_redirect_policy` covers a 401 server alongside the working fixture server. |
| Client extension | Own and document reverse-domain `com.veasel.code`; read only its exact top-level directory and object-valued manifest namespace; ignore every unknown namespace. | Implemented for the documented `display_name` label and for recording that an exact `com.veasel.code` directory resolves inside the package. Unknown namespaces stay opaque. Directory contents are not listed, read, or executed, and the catalog does not return a filesystem path. This is not plugin installation or full conformance. | `plugins_test.v:test_veasel_code_extension_reads_label_and_contained_directory`; `tests/agent_plugins/v1.0.0/plugin-manifests.json` covers a valid label, an unsupported owned-namespace field, an invalid label, and an opaque foreign namespace. |
| User control | The standard leaves permissions and sandboxing to each client. Veasel must display provenance, trust state and exact MCP effects before allowing execution. | Per-session server trust/revocation and explicit per-call review are implemented. Each model-requested MCP call durably stores its server, native tool and bounded exact argument JSON, pauses the turn, and waits for inspect plus approve/reject. Rejected calls never reach the server; restarted pending/approved calls are cancelled and running calls become uncertain without replay. TUI review visibly escapes terminal controls and direction characters. Processes still run with the current user privileges and are not sandboxed. Operators can also add standalone stdio/Streamable HTTP servers outside plugin packages via `GET/POST /v1/mcp-servers` and `PATCH/DELETE /v1/mcp-servers/{name}` (capability `mcp.servers.configured`, synthetic catalog package `configured`, trust as `configured/<name>`, TUI `/mcp add|enable|disable|remove`). | `main_test.v:test_mcp_tool_call_requires_inspection_approval_and_recovers_without_replay`; `configured_mcp_test.v`; API smoke covers inspect/approve/reject and proves fixture effects happen only after approval. MCP server effects remain arbitrary within that process's privileges. OAuth and interactive auth remain open. |
| Veasel plugin management (extension beyond v1) | Add/remove a local plugin directory; enable/disable components independently; display metadata, source path, unsupported items, and trust state; preserve its dedicated data directory across updates. | Partial: package links via `/v1/plugins/links` and TUI `/plugin add|remove` (`plugins.links`). Component enable/disable via `GET/PATCH /v1/plugins/components` (`plugins.components`, `$VEASEL_DATA_DIR/plugin-components.json`); catalog skill/MCP rows expose `enabled`; disabled skills cannot be session-activated and disabled MCP servers cannot be trusted. PLUGIN_DATA remains keyed by plugin name. A broader durable package registry beyond the symlink set remains open. | `plugins_links.v`, `plugins_components.v`, OpenAPI `/v1/plugins/components`. |
| Veasel configured MCP (extension beyond v1) | Add/list/update/remove MCP servers without packaging an Agent Plugin; optional enable/disable; reuse per-session trust and per-call approval. | Shipped for **user** (`$VEASEL_DATA_DIR/mcp-servers.json`), **project** (`<workspace>/.veasel/mcp-servers.json`), and read-only **project-import** of portable `mcpServers` layouts (`.mcp.json`, `.cursor/mcp.json`; not `.vscode/mcp.json`). Precedence for `configured/<name>`: project > project-import (`.mcp.json` then `.cursor/mcp.json`) > user. Plugin servers stay `<plugin>/<server>`. API/TUI and headless `veasel mcp` expose scope; imports are not writable. Stdio and Streamable HTTP only; unexpanded `${…}` entries skipped; named HTTP credentials via `/v1/mcp-credentials`; stdio `notifications/cancelled` on turn cancel; no OAuth dance; no install-script execution. Per-call approval remains mandatory. | `configured_mcp.v`, `mcp_credentials.v`, `headless_mcp.v`, `plugin_mcp_transport.v`, OpenAPI `/v1/mcp-servers` and `/v1/mcp-credentials`, TUI `/mcp`. Interactive OAuth dance remains open. |

## V standard-library reuse

Use the pinned V standard library at `.v-version`: `os`/`filepath` for
canonical roots and file kinds, `json2` for bounded JSON parsing, `yaml` for
Agent Skills frontmatter, `mcp` for MCP client transports and lifecycle, and
`os.Process` for direct executable invocation. Keep package validation,
component discovery, permission policy, and MCP connections behind typed V
interfaces; do not build shell-command parsing or a second MCP wire stack.

The stdlib MCP HTTP adapter does not expose redirect policy. Veasel therefore
uses `net.http.fetch` directly with `allow_redirect: false`, `validate: true`
for HTTPS, bounded body reads and `max_retries: 1` (one attempt). `vlib/mcp`
still handles JSON-RPC, initialization, protocol negotiation and lifecycle.
Configured headers never leave the declared origin because all redirects fail.
Agent Plugins makes legacy HTTP+SSE optional, so Veasel does not claim that
transport. This experimental implementation is not a full conformance claim.

## Current implementation boundary

The API returns plugin metadata from `GET /v1/plugins`. Operator-managed
absolute package links use `GET/POST /v1/plugins/links` and
`DELETE /v1/plugins/links/{name}`; the TUI exposes `/plugins` and
`/plugin add|remove`. Linked packages appear in the catalog with
`origin=link`. Standalone MCP servers (not from a plugin package) persist in
`$VEASEL_DATA_DIR/mcp-servers.json` (user scope) and
`<workspace>/.veasel/mcp-servers.json` (project scope) via
`GET/POST /v1/mcp-servers` and `PATCH/DELETE /v1/mcp-servers/{name}` (optional
`scope` / `directory`); the TUI exposes
`/mcp add|remove|enable|disable` with optional `user|project`. Portable
workspace `.mcp.json` and `.cursor/mcp.json` files with a top-level
`mcpServers` object are imported read-only when a session workspace is active.
They appear under the synthetic catalog package `configured`
(`origin=configured`) and are trusted as `configured/<name>`. Precedence for
the same name: project > project-import > user.
Session Skills are selected with
`GET/POST /v1/sessions/{id}/skills`; the TUI exposes `/skills` and
`/skill on|off <plugin>/<skill>`. MCP servers are listed with `/mcp` and
trusted per session with `/mcp trust <plugin>/<server>`; revoke with
`/mcp untrust <plugin>/<server>`. Stdio and Streamable HTTP servers run; other
transports are skipped. Their MCP
tools are discovered for each turn and routed through the selected model
provider. Every model-requested MCP call pauses the active turn until the user
opens its exact bounded JSON arguments with `/mcp call show <id>` and explicitly
approves or rejects it. `/mcp calls` lists the durable history; approval uses
`/mcp call approve <id>` and rejection uses `/mcp call reject <id>`. An approval
is single-use; rejection is returned to the model as an error, with instructions
not to retry unless the user asks. Pending/approved calls are cancelled at
startup; running calls become uncertain and are never replayed. Each trusted
server stays available for that model turn and closes afterward; only stdio
`PLUGIN_DATA` persists between turns. Stdio processes run
with the current user privileges without an OS sandbox. Tool arguments and results are
sent to the configured provider. Selection is persisted and produces session
events. Skill instructions are bounded, reloaded when composing each turn,
and inserted into explicitly untrusted system context. Active Skills add the
read-only `agent_skill_read_resource` tool for on-demand, bounded UTF-8 files
within that Skill's directory; traversal and symlink escapes are rejected.
Resource and script contents are never executed automatically. The API does not expose
instruction bodies or configured header values through the catalog; remote
origins and header counts are shown for informed trust. `VEASEL_PLUGIN_DIR` overrides the
default `$VEASEL_DATA_DIR/plugins` directory.

Each session can trust at most eight MCP servers. The runtime caps MCP-enabled
turns globally at four; when all slots are occupied, the API returns `503`
with `Retry-After: 1` before starting another plugin process. Older databases
with more than eight trusted entries load the first eight in deterministic
name order so ordinary session chat remains available.

Plugin files can change after selection, so each turn revalidates and reloads
the selected component. If a Skill fails to load, the request fails closed;
an unavailable MCP server is skipped and reported to the server log. Skills do
not grant tools or permissions.

## Release gate

Do not claim Agent Plugins compatibility until every required matrix row has
automated fixture evidence, all core requirements in the pinned spec are
covered, and independent valid components survive neighboring component
failures. Derive and maintain local fixtures from the pinned specification and
schemas, record their requirement mapping here, and include upstream license
notices if any material is vendored. If the upstream repository publishes a
fixture suite, pin its source revision and license before adopting it. Keep the
spec commit, schema hashes, and fixture source revisions in this document when
updated.
