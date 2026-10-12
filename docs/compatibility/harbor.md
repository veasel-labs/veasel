# Harbor custom agent compatibility

Veasel's local Harbor integration targets the installed-agent contract in
Harbor **0.24.0**, source commit
[`dc933be707feafbb9efcdf092cb8a0e391332617`](https://github.com/harbor-framework/harbor/tree/dc933be707feafbb9efcdf092cb8a0e391332617).
The implementation uses `BaseInstalledAgent`,
`harbor.agents.installed.base.with_prompt_template`,
`InstalledAgentOptions`, `BaseEnvironment.exec_as_agent`, and
`AgentContext`/`Trajectory`. Harbor's current custom-agent guide recommends
this class for CLIs installed and run inside the task environment.

The adapter installs the exact Linux x86_64 Veasel release from the official
GitHub release archive and verifies it against `SHA256SUMS`. The Linux release
is built on Ubuntu 22.04 to keep its glibc requirement compatible with Debian
12. SQLite is included in the executable from V's checksum-verified bundled
amalgamation, so the task image does not need a separate SQLite runtime
package. The adapter requires glibc 2.35 or newer. It launches
`veasel run` with an isolated data directory, a dynamically selected loopback
port, explicit provider/model configuration, an ATIF trace destination, and
the autonomous opt-in. It keeps provider usage and cost unavailable when the
V provider interface does not report authoritative values.

Supported Harbor providers are `openai`, `anthropic`, `google` (mapped to
Veasel's `gemini` provider), `gemini`, and `openai-compatible`. Other Harbor
providers fail with a clear error instead of being silently translated.
Configured Harbor base URLs are passed through. Set `--veasel-timeout` to
change the task deadline; the Harbor environment command has a slightly larger
hard timeout so it can shut down the Veasel server and flush task artifacts.
The adapter does not yet expose a reasoning-effort setting because the current
Veasel provider configuration has no such control.

The adapter is custom/local; Veasel is not in Harbor's built-in agent registry.
Harbor's contribution policy asks contributors to discuss interface or core
logic changes first and requires the human author to write the initial and
final PR drafts. This implementation does not claim upstream support or
leaderboard participation.
