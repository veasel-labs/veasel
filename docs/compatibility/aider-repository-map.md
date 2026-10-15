# Aider repository map — study pin

**Upstream:** [Aider-AI/aider](https://github.com/Aider-AI/aider)
**Pinned commit:** [`5dc9490bb35f9729ef2c95d00a19ccd30c26339c`](https://github.com/Aider-AI/aider/tree/5dc9490bb35f9729ef2c95d00a19ccd30c26339c)
**Primary source:** [`aider/repomap.py`](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/repomap.py)
**License:** Apache-2.0
**Study date:** 2026-10-15

## What was studied

Aider's `RepoMap` builds a syntax-aware repository map with tree-sitter tag
queries, SQLite/disk caches, NetworkX PageRank over definition/reference edges,
personalization from chat files and mentioned identifiers, and a binary search
that fits the rendered tree into a token budget.

## What Veasel adapted (principles only)

Veasel ships a **V-native extractive** map inspired by Aider's product goal
(bounded structural context for coding turns), not a port of Aider code:

- Walk the session workspace with the same ignore roots as workspace tools.
- Extract declaration-like symbols with line-prefix heuristics (not tree-sitter).
- Rank paths/symbols with mention weighting, important-file boosts,
  test/source pairing, same-directory neighbors, and cross-directory
  same-basename-stem siblings (not NetworkX PageRank).
- Fit output to a measured UTF-8 byte budget and report a conservative bytes/4
  token bound.
- Inject a **sticky** hint-free map into the system prompt so the prefix stays
  byte-stable across turns for prompt-cache hits; attach a compact
  mention-ranked focus block to the user message only when the prompt names
  paths or code-like identifiers (directory/prefix and segment boosts included).
- Mark map text untrusted; do not execute files or follow embedded instructions.
- Expose `GET /v1/sessions/{id}/workspace/map`, capability
  `workspace.repository_map` / `session.repository_map`, and
  `session.repository_map` events when a turn injects the map.

## What was not copied

No Aider Python source, tree-sitter queries, PageRank graph construction, or
cache schema was copied into this repository. Reuse of Aider code would require
a separate license/attribution review beyond this study pin.
