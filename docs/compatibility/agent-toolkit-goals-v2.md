# Agent Toolkit Goal v2 compatibility

Veasel accepts the portable Goal v2 permission declaration contract from Agent Toolkit. It preserves the requested policy ceiling and each task's permission list through manifest persistence and the read-only task projection.

## Verified upstream source

- Repository: `ulises-jeremias/agent-toolkit`
- Current upstream main inspected on 2026-11-27: `f0290c17090ec4ee474bd9871aa4a2350c321ae1`
- Canonical schema: `schemas/goal-v2.schema.json`
- Validator and exporter: `modules/agent_toolkit_core/goals.v`
- Fixture: `tests/fixtures/goals/permissions.yaml`
- Veasel fixture: [`testdata/agent-toolkit-goal-v2-permissions.json`](../../testdata/agent-toolkit-goal-v2-permissions.json)
- Veasel fixture SHA-256: `6f551c37178d48182a63b36f69fda00a69ef0b0d8e8e6bd34695372f7dabd19a`
- The checked-in fixture was derived from Toolkit commit
  `8d24e7bfc4eda469fb9ff3b1b1fb75003e8d9569`; it is synthetic contract data,
  not execution evidence. Current upstream schema additionally makes each
  task's permission list a subset of the Goal-level `policy_ceiling`. Veasel's
  Goal v2 admission validates that relationship before persisting the
  manifest.

The declarations express intent and a Goal-level ceiling. They do not grant
access. Until Veasel intersects these effects with runtime policy and enforces
them during execution, Veasel rejects v2 task dispatch before any claim,
worktree, or session side effect. Goal v1 retains its existing admission and
dispatch behavior, and permission fields are rejected in v1, including empty
fields and downgrade-shaped manifests.
