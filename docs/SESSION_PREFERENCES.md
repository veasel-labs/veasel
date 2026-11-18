# Session preferences (epic #689)

Provider, model, and permission mode are chosen **per session** and stored by
the server in the session store. The TUI and Desktop render and resume the
same values; neither keeps its own copy.

## Data model (store migration 31)

`sessions` gains `preferred_provider`, `preferred_model`, `permission_mode`
(`ask` | `accept-edits` | `plan` | `bypass`, default `ask`, enforced by a
`CHECK`), and `prefs_version` (optimistic-concurrency token).
`session_operations` gains `resolved_provider`, `resolved_model`,
`permission_mode`, and `target_source` to stamp what each turn was admitted
with.

`GET /v1/sessions` and `GET /v1/sessions/:id` also return `last_provider` and
`last_model`: the provider/model of the latest **completed** turn, read from
`session_operations`. They describe what ran, never what is preferred.

## Resolution order

For every turn, at admission:

1. explicit per-turn `provider` / `model` / `permission_mode` on the POST;
2. the session preference;
3. the global default (model settings).

The admitted turn carries explicit, resolved values (queued turns persist
them in `request_json`), so a later preference change cannot alter a turn
already admitted. A `session.turn_resolved` event records the resolution for
every turn, including synchronous ones that have no operation row.

Validation matches per-turn targets: provider and model together, or an
installed-CLI provider alone; a model alone is rejected. A permission mode the
resolved CLI provider cannot honor fails closed (`409
session_permission_unsupported`) instead of being downgraded.

If the stored provider is no longer available the turn fails with `409
session_provider_unavailable`. Veasel never runs a different provider than the
one displayed.

## Concurrency and safety

- `PATCH /v1/sessions/:id` requires `expected_prefs_version` for any
  preference field; a stale value returns `409 prefs_version_conflict` with the
  current session.
- Changes are refused (`409 session_busy`) while a turn is queued, running, or
  cancelling.
- `bypass` requires `confirm_bypass: true` and writes a
  `session.permission_bypass_confirmed` event in the same transaction. It is
  never a default, and `POST /v1/sessions/:id/fork` copies the provider/model
  but resets the permission mode to `ask`.
- A turn that resolves to `bypass` writes the same audit event, naming the
  operation.
- The `VEASEL_CLI_PERMISSION_MODE` environment default no longer widens a
  session turn: every session has an explicit stored mode.

## Rollback and downgrade

Migration 31 only adds columns with defaults (`ALTER TABLE ... ADD COLUMN`),
so it is forward-compatible:

- A v30 binary opens a v31 database and ignores the new columns. Its writes
  use column defaults, so no data is lost.
- Choices made while on v31 are not honored by a v30 binary (it uses the
  global default) but are preserved and apply again after re-upgrading.
- The `schema_migrations` ledger keeps version 31; a v30 binary tolerates a
  newer ledger. To fully undo, restore the pre-upgrade backup of
  `veasel.sqlite3`; no manual SQL is required.
