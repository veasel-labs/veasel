# Real-task benchmark cases

This directory holds versioned coding tasks and a standard-library runner. It
starts small: `website-173` pins the repository commit, exact prompt hash,
Qwen3:8b model digest, Ollama version, CUDA/GPU, permissions, context/output budgets, wall limit, and a memory safety
floor. The runner rejects drift or insufficient host resources before starting
an attempt. Resource aborts and timeouts are distinct outcomes and are never
scored as coding failures.

## Prepare and preflight

Use a disposable checkout at the case's exact base commit. Keep it clean and
make sure its `origin` URL matches the case. Start the exact Ollama model tag
locally; the preflight queries `/api/tags` and `/api/version` and compares the
model digest and Ollama version. This initial case is specific to the RTX 3060
CUDA run. Other hardware needs a separately versioned case before its results
can be compared.

```sh
python3 benchmarks/real-task/run.py preflight \
  --workspace /path/to/disposable/website-checkout \
  --data-dir /benchmark/state
```

The website case currently requires at least 9 GiB available RAM and 2 GiB
free swap. These thresholds reflect observed Qwen3:8b memory use on the
workstation and avoid repeating the recent resource-aborted runs. A failed
preflight exits with status 2 and lists the unmet checks.

## Run Veasel

Run only inside an externally isolated, disposable task environment with no
host home mounts, unrelated secrets, or writable paths beyond the task checkout
and isolated Veasel state. The confirmation flag records that operator
assertion; it does not create or verify a sandbox. The local Veasel provider
configuration must already point at the pinned local model. No paid API is
used.

```sh
python3 benchmarks/real-task/run.py run \
  --workspace /path/to/disposable/website-checkout \
  --data-dir /benchmark/state \
  --artifacts /path/to/private-attempt-artifacts \
  --sandbox-confirmed
```

The runner sets the pinned context and output limits itself, samples available
RAM and swap once per second, and stops the client if either drops below the
case floor. Private ATIF and client logs stay in the chosen artifact directory;
do not publish them without reviewing and sanitizing source, prompts, and tool
I/O. `attempt.json` records versions, hashes, timing, resource samples, and one
of `completed`, `resource_aborted`, `timeout`, or `agent_error`. A completed
turn is still **unscored** until an independent reviewer checks the expected
diff and task-specific tests against the external oracle.

This first version samples host available RAM and swap. It does not yet collect
CPU, process/GPU peak memory, or provider-reported token usage, so reports are
not complete comparative benchmark records and cannot support efficiency or
speed claims.

The OpenCode baseline still needs an adapter that consumes the same case,
workspace, Ollama model digest, limits, resource sampling, and oracle. Do not
compare runs produced by a different case revision or prompt hash.
