# Harbor adapter smoke task

This deterministic, one-trial task verifies the installed-agent path without a
paid model account. Its in-container OpenAI-compatible fixture emits a fixed
streaming tool call; the verifier checks the resulting file. Harbor runs Veasel
as an unprivileged user in its disposable task container and validates the
exported ATIF trajectory.

This is an integration smoke test, not a coding benchmark or leaderboard result.
It measures neither model capability nor Veasel performance. The task needs
Docker and network access to fetch the exact Veasel release and build the task
image. It sends no task data to an external model service and uses a dummy API
key.

From the Veasel repository root, set `VEASEL_VERSION` to an exact published
release (without a leading `v`) and run:

```sh
VEASEL_VERSION=0.20.0-next.0 benchmarks/harbor/smoke.sh
```

The resulting Harbor job directory contains the task result, verifier reward,
Veasel result JSON, and ATIF trajectory. Inspect those artifacts locally;
trajectories can include prompts and task workspace data and must not be
published without review.
