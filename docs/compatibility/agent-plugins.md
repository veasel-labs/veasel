# Agent Plugins v1.0.0 conformance plan

**Normative release:** Agent Plugins 1.0.0, tag commit
[`bd383552095128f6effe895b9257cfd580a6d179`](https://github.com/agentplugins/agent-plugins-spec/tree/bd383552095128f6effe895b9257cfd580a6d179)
**Release date:** 2026-09-28
**Agent Skills source:** [official Skills specification](https://agentskills.io/specification)
**MCP protocol revision:** [2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28)
**Veasel status:** experimental loader code is in progress; it is not yet
validated, integrated with sessions, or conformant.

The v1 portable package contains a root `plugin.json` and optional components
in the fixed `skills/` and `mcp.json` locations. Plugin directory installation,
updates, permissions, sandboxing, skill presentation, and Veasel-specific
extensions are client behavior outside the portable format. Veasel will use
its stable namespace `com.veasel.code` for any client-owned manifest data and
files. Conformance claims apply to the pinned 1.0.0 release only; draft 1.1.0
is not treated as a released contract.

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
| Package boundary | Load from one directory; resolve every package path and reject symlink/junction escapes. | Partial implementation; unverified | Fixture trees with valid in-root links, escaping links, missing paths, and platform-specific path cases. |
| Manifest first | Read root `plugin.json` before component discovery; select a locally supported schema from canonical `$schema`. | Partial implementation; unverified | No network during load; tests for missing/unsupported schema and malformed JSON. |
| Closed manifest | Permit only the defined root fields. Required non-empty `$schema` and `name`; name grammar/length; metadata and author types. | Partial implementation; unverified | Official schema fixtures plus targeted RFC 2119 edge cases. |
| Non-fatal manifest cases | Report and ignore unknown root fields; report and ignore a non-object `extensions`; ignore unsupported namespaces without validating their values. Other schema violations reject the whole plugin. | Partial implementation; unverified | Tests prove exact failure boundary and no components execute after fatal validation. |
| Fixed discovery | Missing locations are valid. Discover only immediate `skills/<child>/SKILL.md` and root `mcp.json`; validate expected filesystem kinds. | Partial implementation; unverified | Nested-skill decoys, absent/invalid directories, file-vs-directory cases, symlink escape cases. |
| Agent Skills | Validate YAML frontmatter and required/optional fields per Agent Skills; require name to match parent directory; skip invalid skill alone; preserve optional files and directories. | Partial implementation; unverified | Skills conformance fixtures and isolation tests; implement experimental `allowed-tools` only as a restriction intersected with Veasel/user policy, never as self-granted authority. |
| MCP document | Read only root `mcp.json`; validate canonical schema version equals `plugin.json`; closed top-level fields and independent server entries. | Partial implementation; unverified | Official schema fixtures, mismatched version, unknown fields, per-entry isolation. |
| MCP transports | Support stdio and Streamable HTTP; also evaluate optional legacy HTTP+SSE. Use declared transport without silent fallback. | Not implemented in Veasel. V `vlib/mcp` provides stdio and Streamable HTTP clients, but its current HTTP adapter does not expose redirect policy and uses `http.fetch` defaults that permit redirects. | End-to-end fixture servers for every claimed transport, initialization/handshake, tools, cancellation, and clean shutdown. Before passing configured plugin headers, use a transport adapter that disables redirects or otherwise proves they cannot cross origins. |
| MCP stdio config | One executable token; bare name or contained `./` package path; no expansion in command; default cwd is plugin root; strict cwd roots and containment. | Partial config validation; no process launch | Tests for command-token behavior, cwd forms, executable resolution, no shell interpolation, and containment. |
| MCP variables and environment | Set absolute `PLUGIN_ROOT` and persistent per-install `PLUGIN_DATA`; expand exact placeholders once in args/env/cwd only; reserved env names invalid; secrets are not portable. | Partial single-pass helper and cwd containment; no persistent data root or process environment wiring | Expansion fixtures including recursive-looking values, unknown placeholders, name collisions, update-persistent data. |
| MCP HTTP config | Absolute HTTP(S) URL; no userinfo/fragment; HTTPS off-loopback; literal validated headers; reject case-insensitive duplicates; no redirects forwarding configured headers across origins. | Partial URL/header validation; no HTTP client runtime | URL/header matrix, loopback literal checks, redirect-origin test, no credential leakage. |
| Failure isolation | Invalid MCP config disables only MCP; invalid entries/unsupported transports/connection failures skip that server; independent skills still load. | Partial at package-validation level; no connection runtime | Mixed valid/invalid plugin fixtures prove unaffected components load. |
| Client extension | Own and document reverse-domain `com.veasel.code`; read only its exact top-level directory and object-valued manifest namespace; ignore every unknown namespace. | Not implemented | Fixtures for own extension behavior and opaque ignored namespace values. |
| User control | The standard leaves permissions and sandboxing to each client. Veasel must display provenance, trust state and exact MCP effects before allowing execution. | Not implemented | Durable approval, revocation, process lifecycle and tool-level permission tests. |
| Veasel plugin management (extension beyond v1) | Add/remove a local plugin directory; enable/disable components independently; display metadata, source path, unsupported items, and trust state; preserve its dedicated data directory across updates. | Not implemented | TUI and API flows, durable registry state, remove/re-enable behavior, and upgrade data-preservation tests. |

## V standard-library reuse

Use the pinned V standard library at `.v-version`: `os`/`filepath` for
canonical roots and file kinds, `json2` for bounded JSON parsing, `yaml` for
Agent Skills frontmatter, `mcp` for MCP client transports and lifecycle, and
`os.Process` for direct executable invocation. Keep package validation,
component discovery, permission policy, and MCP connections behind typed V
interfaces; do not build shell-command parsing or a second MCP wire stack.

The stdlib MCP client currently documents stdio and Streamable HTTP support,
but its HTTP adapter does not expose redirect control while `net.http` follows
redirects by default. Since plugin MCP headers are origin-bound, Veasel must
use a no-redirect adapter or a verified upstream fix before sending configured
headers. Do not use `mcp.connect_http` with plugin-provided headers as-is.
Agent Plugins makes legacy HTTP+SSE optional, so Veasel will not claim support
for that transport until a fixture proves the complete client lifecycle. A
conformant plugin client still has to implement Skills or MCP; Veasel targets
both, and supports both required/recommended MCP transports.

## Release gate

Do not claim Agent Plugins compatibility until every required matrix row has
automated fixture evidence, all core requirements in the pinned spec are
covered, and independent valid components survive neighboring component
failures. Add the official schemas/conformance fixtures with their upstream
license notices before using or vendoring them. Keep the spec commit, schema
hashes, and fixture source revisions in this document when updated.
