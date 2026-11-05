#!/usr/bin/env python3
"""Deterministic fixture benchmark for Veasel's headless agent loop.

Runs scripted coding tasks against the repository's mock OpenAI-compatible
provider (`scripts/mock-provider.py`). No network, no paid models, no
randomness: the provider replies are fixed, so every run exercises the same
model-visible conversation and the score depends only on Veasel's harness
( tool orchestration, edit application, trace accounting ).

Each task is scored by an external check on the resulting workspace, never
by the agent's own final message. The JSON report records wall time, ATIF
step/tool-call counts and provider-reported token usage so future
same-model comparisons against other harnesses can reuse the same fixtures,
scoring and report shape.

Usage:
    python3 benchmarks/deterministic/run.py --veasel /path/to/veasel \
        [--report benchmarks/reports/deterministic-<date>.json] [--keep]

Exit status is non-zero when any task fails its check.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.request import Request, urlopen

REPO_ROOT = Path(__file__).resolve().parents[2]
MOCK_PROVIDER = REPO_ROOT / "scripts" / "mock-provider.py"
FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"

INITIAL_MAIN_V = "module fixture\n\n// workspace-search-sentinel\n"
EXPECTED_GREET = "fn greet(name string) string {"


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def seed_workspace(task: dict, workspace: Path) -> None:
    """Seed the task workspace: a vendored fixture tree when the task
    names one (seed_workspace), else the synthetic src/main.v."""
    seed = task.get("seed_workspace")
    if seed:
        shutil.copytree(FIXTURES_DIR / seed, workspace, dirs_exist_ok=True)
        return
    (workspace / "src").mkdir(parents=True)
    (workspace / "src" / "main.v").write_text(INITIAL_MAIN_V, encoding="utf-8")


def run_check_command(task: dict, workspace: Path) -> bool:
    """Independent post-run oracle (e.g. the seeded project's own tests).
    `{v}` in argv resolves to the V compiler on PATH; missing V fails."""
    argv = []
    for arg in task["check_command"]:
        if arg == "{v}":
            compiler = shutil.which("v")
            if compiler is None:
                print("check_command: v compiler not found on PATH", file=sys.stderr)
                return False
            argv.append(compiler)
        else:
            argv.append(arg)
    home = workspace.parent / "check-home"
    home.mkdir(exist_ok=True)
    env = dict(os.environ, HOME=str(home), VJOBS="1")
    completed = subprocess.run(argv, cwd=workspace, env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               timeout=300)
    return completed.returncode == 0


def wait_healthy(port: int, process: subprocess.Popen, timeout: float = 15.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"process exited early with {process.returncode}")
        try:
            with urlopen(f"http://127.0.0.1:{port}/v1/health", timeout=0.5) as response:
                if response.status == 200:
                    return
        except OSError:
            time.sleep(0.05)
    raise TimeoutError(f"server on port {port} did not become healthy")


def rss_kib(pid: int) -> int | None:
    """Resident set size from /proc (Linux); None where unavailable."""
    try:
        for line in Path(f"/proc/{pid}/status").read_text(encoding="utf-8").splitlines():
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    except OSError:
        pass
    return None


def percentile(values: list[float], q: float) -> float:
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round(q / 100 * len(ordered)) - 1))
    return ordered[index]


def measure_startup(veasel: Path, runs: int, work_root: Path) -> dict:
    """Cold-start samples: spawn `veasel serve` on a fresh data dir, time
    to the first /v1/health body with healthy=true, sample idle RSS."""
    samples_ms: list[float] = []
    rss_samples: list[int] = []
    for index in range(runs):
        port = free_port()
        data_dir = work_root / f"startup-{index}"
        data_dir.mkdir()
        env = dict(os.environ)
        env.update(
            VEASEL_PORT=str(port),
            VEASEL_DATA_DIR=str(data_dir),
            VEASEL_MODEL_PROVIDER="openai-compatible",
            VEASEL_MODEL="smoke-model",
            VEASEL_MODEL_API_KEY="startup-probe-key",
            VEASEL_MODEL_BASE_URL="http://127.0.0.1:9/v1",
        )
        started = time.monotonic()
        process = subprocess.Popen(
            [str(veasel), "serve"], env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        try:
            deadline = started + 15
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError(f"startup probe server exited early with {process.returncode}")
                try:
                    with urlopen(f"http://127.0.0.1:{port}/v1/health", timeout=0.5) as response:
                        if json.load(response).get("healthy"):
                            samples_ms.append(round((time.monotonic() - started) * 1000, 1))
                            rss = rss_kib(process.pid)
                            if rss is not None:
                                rss_samples.append(rss)
                            break
                except OSError:
                    time.sleep(0.002)
            else:
                raise TimeoutError("startup probe server did not become healthy")
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
    summary = {
        "runs": runs,
        "samples_ms": samples_ms,
        "p50_ms": percentile(samples_ms, 50),
        "p95_ms": percentile(samples_ms, 95),
        "max_ms": max(samples_ms),
        "rss_kib_p50": int(percentile([float(r) for r in rss_samples], 50)) if rss_samples else None,
    }
    return summary


def trace_metrics(trace_path: Path) -> dict:
    """Summarize an ATIF trajectory without trusting the agent's prose."""
    if not trace_path.exists():
        return {"trace_present": False}
    trace = json.loads(trace_path.read_text(encoding="utf-8"))
    steps = trace.get("steps", [])
    tool_calls = 0
    for step in steps:
        message = step.get("message")
        if isinstance(message, dict):
            tool_calls += len(message.get("tool_calls", []) or [])
        if step.get("tool_calls"):
            tool_calls += len(step["tool_calls"])
    metrics = trace.get("final_metrics") or {}
    return {
        "trace_present": True,
        "outcome": trace.get("extra", {}).get("outcome"),
        "token_usage": trace.get("extra", {}).get("token_usage"),
        "steps": len(steps),
        "tool_calls": tool_calls,
        "prompt_tokens": metrics.get("total_prompt_tokens"),
        "completion_tokens": metrics.get("total_completion_tokens"),
    }


TASKS = [
    {
        "id": "autonomous-workspace-edit",
        "prompt": "Autonomous workspace edit",
        "check": lambda ws: EXPECTED_GREET in (ws / "src" / "main.v").read_text(encoding="utf-8"),
        "check_description": "src/main.v contains the applied greet function",
        # The generic competitor providers (scripted_provider.py,
        # responses_provider.py) can only drive one unconditional write of
        # the greet content, so this is the only task whose oracle they can
        # satisfy non-vacuously. Every other task's check would either fail
        # for protocol reasons or pass without proving its description
        # (chaining, recovery, boundaries). Mark eligibility explicitly
        # instead of filtering on incidental fields.
        "competitor": True,
    },
    {
        "id": "autonomous-multi-file-edit",
        "prompt": "Autonomous multi-file edit",
        # The scripted model applies the greet edit to src/main.v first; only
        # after that tool result does the provider request a second edit
        # creating src/helper.v. A pass proves sequential multi-file tool
        # orchestration in one run, scored on external workspace state.
        "check": lambda ws: EXPECTED_GREET in (ws / "src" / "main.v").read_text(encoding="utf-8") and "multi-file-helper-sentinel" in (ws / "src" / "helper.v").read_text(encoding="utf-8"),
        "check_description": "two sequential edits applied in one run: greet in src/main.v and helper created in src/helper.v",
        "expect_response": "Autonomous multi-file edit applied.",
    },
    {
        "id": "read-then-edit",
        "prompt": "Read then edit workspace",
        # The scripted model first reads src/main.v; only after that read
        # result (containing the sentinel) does the provider request the
        # greet edit. A pass proves read->edit chaining in one run.
        "check": lambda ws: EXPECTED_GREET in (ws / "src" / "main.v").read_text(encoding="utf-8"),
        "check_description": "read of src/main.v is followed by the applied greet edit in the same run",
        "expect_response": "Read then edit applied.",
    },
    {
        "id": "edit-then-shell-verify",
        "prompt": "Edit then verify workspace",
        # The scripted model applies the greet edit, then verifies it with a
        # shell grep in the same run. A pass proves edit->shell verification
        # chaining, scored on the final file contents.
        "check": lambda ws: EXPECTED_GREET in (ws / "src" / "main.v").read_text(encoding="utf-8"),
        "check_description": "greet edit applied and verified by a shell grep in the same run",
        "expect_response": "Edit verified by shell.",
    },
    {
        "id": "failed-shell-then-edit",
        "prompt": "Recover after failed check",
        # The scripted model first greps for the greet function, which is
        # not there yet, so the shell tool reports a failed exit code. Only
        # after that failed tool result does the provider request the greet
        # edit. A pass proves the loop feeds tool failures back to the model
        # and recovers, scored on the final file contents.
        "check": lambda ws: EXPECTED_GREET in (ws / "src" / "main.v").read_text(encoding="utf-8"),
        "check_description": "a failing shell check is followed by the applied greet edit in the same run",
        "expect_response": "Recovered after failed check.",
    },
    {
        "id": "failed-edit-then-retry",
        "prompt": "Recover after failed edit",
        # The scripted model first proposes an edit whose content is
        # identical to the current file, so the edit tool rejects it with
        # a "no changes" error. Only after that error tool result does the
        # provider request the real greet edit. A pass proves the loop
        # feeds edit failures back to the model and recovers, scored on
        # the final file contents.
        "check": lambda ws: EXPECTED_GREET in (ws / "src" / "main.v").read_text(encoding="utf-8"),
        "check_description": "a rejected no-change edit is followed by the applied greet edit in the same run",
        "expect_response": "Recovered after failed edit.",
    },
    {
        "id": "fix-failing-test",
        "prompt": "Fix failing test",
        # The scripted model first runs the workspace check, which fails
        # because the greet function does not exist yet. Only after that
        # failed result does it apply the greet edit, then it re-runs the
        # same check and it passes. A pass proves the fail->fix->re-verify
        # self-correction loop, scored on the final file contents.
        "check": lambda ws: EXPECTED_GREET in (ws / "src" / "main.v").read_text(encoding="utf-8"),
        "check_description": "a failing shell check is fixed by the greet edit and the re-run check passes in the same run",
        "expect_response": "Fixed failing test.",
    },
    {
        "id": "vendored-project-fix",
        "prompt": "Fix vendored project tests",
        # A real multi-file V project (fixtures/token-bucket) with a planted
        # bug: Bucket.allow never refills, so its own test suite fails. The
        # scripted model reads the implementation, applies the refill fix,
        # and shell-verifies it. Scoring is independent of all of that: the
        # harness runs the project's own `v test .` in the resulting
        # workspace and requires the test file to be byte-identical to the
        # seed, so weakening tests cannot pass. The seed fails `v test`
        # (verified when the fixture was added), so the oracle discriminates.
        "seed_workspace": "token-bucket",
        "check": lambda ws: (ws / "token_bucket_test.v").read_text(encoding="utf-8")
            == (FIXTURES_DIR / "token-bucket" / "token_bucket_test.v").read_text(encoding="utf-8"),
        "check_command": ["{v}", "test", "."],
        "check_description": "vendored token-bucket project: its own `v test .` passes after the run and its test file is unchanged",
        "expect_response": "Vendored project fixed.",
        "veasel_only": True,
    },
    {
        "id": "greeting-reply",
        "prompt": "Say hello",
        "check": lambda ws: True,  # scored from the run result below
        "check_description": "headless run completes with the fixture reply",
        "expect_response": "Provider fixture reply",
    },
    {
        "id": "inspect-workspace",
        "prompt": "Inspect workspace",
        "check": lambda ws: True,  # scored from the run result below
        "check_description": "workspace search finds the sentinel without modifying files",
        "expect_response": "Found workspace-search-sentinel",
    },
    {
        "id": "autonomous-shell",
        "prompt": "Autonomous shell",
        # The fixture command asserts VEASEL_MODEL_API_KEY is absent from the
        # shell environment and prints a marker; the workspace must stay
        # byte-identical, so a pass proves shell orchestration happened
        # without an edit and without leaking the provider key.
        "check": lambda ws: (ws / "src" / "main.v").read_text(encoding="utf-8") == INITIAL_MAIN_V,
        "check_description": "shell tool runs with no provider key in its env; workspace unchanged",
        "expect_response": "Autonomous shell completed.",
    },
    {
        "id": "outside-write-rejected",
        "prompt": "Try to write outside",
        # Symmetric to outside-read-rejected: the scripted edit targets
        # ../outside/evil.txt. The mock provider accepts the follow-up only
        # when the tool result is an error, and the external check verifies
        # no file appeared outside the workspace.
        "check": lambda ws: (ws / "src" / "main.v").read_text(encoding="utf-8") == INITIAL_MAIN_V and not (ws.parent / "outside" / "evil.txt").exists(),
        "check_description": "write outside the workspace is rejected; no outside file created",
        "expect_response": "The path was rejected.",
    },
    {
        "id": "interrupted-stream-fails",
        "prompt": "Stream then drop",
        # The mock provider truncates the response mid-body and drops the
        # connection (Content-Length promises more than arrives). A pass
        # proves the run surfaces a failure instead of reporting success
        # or hanging, and the workspace stays byte-identical.
        "check": lambda ws: (ws / "src" / "main.v").read_text(encoding="utf-8") == INITIAL_MAIN_V,
        "check_description": "interrupted provider stream fails the run with an error; workspace unchanged",
        "expect_failure": True,
        "veasel_only": True,
    },
    {
        "id": "wrong-api-key-fails",
        "prompt": "Say hello",
        # The mock provider answers 401 for any key it does not know. A
        # pass proves the run fails fast with the HTTP status in the
        # error, the workspace stays byte-identical, and the rejected key
        # is never echoed into the result or trace output.
        "env": {"VEASEL_MODEL_API_KEY": "wrong-fixture-key"},
        "check": lambda ws: (ws / "src" / "main.v").read_text(encoding="utf-8") == INITIAL_MAIN_V,
        "check_description": "wrong API key fails the run with HTTP 401 surfaced; workspace unchanged; key never echoed",
        "expect_failure": True,
        "expect_error_contains": "rejected the API key (HTTP 401)",
        "forbid_in_outputs": ["wrong-fixture-key"],
        "veasel_only": True,
    },
    {
        "id": "unreachable-endpoint-fails",
        "prompt": "Say hello",
        # The base URL points at a closed local port, so the connection is
        # refused. A pass proves the run fails fast with copy naming the
        # unreachable endpoint (not a generic failure), and the workspace
        # stays byte-identical.
        "env": {"VEASEL_MODEL_BASE_URL": "http://127.0.0.1:{closed_port}/v1"},
        "check": lambda ws: (ws / "src" / "main.v").read_text(encoding="utf-8") == INITIAL_MAIN_V,
        "check_description": "unreachable provider endpoint fails the run with endpoint guidance; workspace unchanged",
        "expect_failure": True,
        "expect_error_contains": "Could not reach the model provider endpoint",
        "veasel_only": True,
    },
    {
        "id": "unknown-model-fails",
        "prompt": "Say hello",
        # The provider answers 404 model_not_found for this model ID. A
        # pass proves the run fails with copy pointing at the model ID /
        # base URL, and the workspace stays byte-identical.
        "env": {"VEASEL_MODEL": "no-such-model"},
        "check": lambda ws: (ws / "src" / "main.v").read_text(encoding="utf-8") == INITIAL_MAIN_V,
        "check_description": "unknown model ID fails the run with model/endpoint guidance; workspace unchanged",
        "expect_failure": True,
        "expect_error_contains": "could not find the model or endpoint (HTTP 404)",
        "veasel_only": True,
    },
    {
        "id": "saved-profile-missing-key",
        "prompt": "Say hello",
        # A saved Anthropic profile names a model but holds no key, and the
        # environment provides none either. A pass proves the run is
        # refused up front with the no-model-configured guidance (never a
        # generic failure, never a provider call) and the workspace stays
        # byte-identical.
        "env": {"VEASEL_MODEL_API_KEY": "", "ANTHROPIC_API_KEY": ""},
        "seed_data_files": {
            "model-settings.json": json.dumps({
                "active_provider": "anthropic",
                "profiles": {
                    "anthropic": {
                        "model": "claude-fixture",
                        "base_url": "https://api.anthropic.com/v1",
                        "api_key": "",
                        "max_output_tokens": 0,
                    }
                },
            }),
        },
        "check": lambda ws: (ws / "src" / "main.v").read_text(encoding="utf-8") == INITIAL_MAIN_V,
        "check_description": "saved profile without a key is refused with no-model guidance; workspace unchanged",
        "expect_failure": True,
        "expect_error_contains": "No model provider is configured",
        "veasel_only": True,
    },
    {
        "id": "cancelled-shell-tool",
        "prompt": "Run slow shell",
        # API-driven (see run_cancel_tool_task): the scripted shell sleeps
        # 5s and only then writes cancel-effect.txt. The turn is cancelled
        # while the command is running; a pass proves the operation ends
        # cancelled, ends promptly, and the effect file never appears even
        # after outwaiting the sleep.
        "kind": "cancel_tool",
        "check": lambda ws: (ws / "src" / "main.v").read_text(encoding="utf-8") == INITIAL_MAIN_V and not (ws / "cancel-effect.txt").exists(),
        "check_description": "cancelling mid-shell kills the command; operation cancelled; no effect file after outwaiting it",
        "veasel_only": True,
    },
    {
        "id": "queue-recovery-order",
        "prompt": "Wait for cancellation",
        # API-driven (see run_queue_recovery_task): one running turn blocked
        # on the provider plus two queued turns, then a backend restart on
        # the same data dir. A pass proves the running turn surfaces as
        # uncertain (never replayed) and the queued turns resume and
        # complete in FIFO order with no duplicated messages.
        "kind": "queue_recovery",
        "check": lambda ws: (ws / "src" / "main.v").read_text(encoding="utf-8") == INITIAL_MAIN_V,
        "check_description": "queued turns resume in FIFO order after restart; running turn uncertain; transcript ordered, no duplicates",
        "veasel_only": True,
    },
    {
        "id": "missing-sandbox-fails-closed",
        "prompt": "Run shell effect",
        # PATH points nowhere, so bubblewrap cannot be located while the
        # sandbox mode is require. The scripted command would write
        # shell-effect.txt; a pass proves autonomous shell execution
        # fails closed (no unsandboxed fallback, no file) and the model is
        # told the sandbox is unavailable instead of the command running.
        "env": {"PATH": "/nonexistent-veasel-fixture", "VEASEL_SHELL_SANDBOX": "require"},
        "check": lambda ws: (ws / "src" / "main.v").read_text(encoding="utf-8") == INITIAL_MAIN_V and not (ws / "shell-effect.txt").exists(),
        "check_description": "missing sandbox backend fails closed: command never runs, no effect file, workspace unchanged",
        "expect_response": "Shell sandbox unavailable.",
        "veasel_only": True,
    },
    {
        "id": "worktree-isolation",
        "prompt": "Autonomous workspace edit",
        # API+git driven (see run_worktree_isolation_task): the edit is
        # applied in a linked worktree on its own branch. A pass proves
        # the main checkout stays byte-identical with a clean git status
        # while the worktree carries the edit as an uncommitted change on
        # the new branch.
        "kind": "worktree_isolation",
        "check": lambda ws: (ws / "src" / "main.v").read_text(encoding="utf-8") == INITIAL_MAIN_V,
        "check_description": "edit lands only in the linked worktree; main checkout byte-identical and git-clean",
        "veasel_only": True,
    },
    {
        "id": "outside-read-rejected",
        "prompt": "Try to read outside",
        # The scripted tool call asks for ../outside/secret.txt. The mock
        # provider rejects the follow-up request unless the tool result is
        # an error, so a pass proves the workspace boundary held and no
        # outside content reached the model.
        "check": lambda ws: (ws / "src" / "main.v").read_text(encoding="utf-8") == INITIAL_MAIN_V,
        "check_description": "read outside the workspace is rejected; workspace unchanged",
        "expect_response": "The path was rejected.",
    },
]


def run_task(veasel: Path, provider_port: int, task: dict, work: Path) -> dict:
    workspace = work / "workspace"
    seed_workspace(task, workspace)

    port = free_port()
    data_dir = work / "data"
    for name, content in task.get("seed_data_files", {}).items():
        data_dir.mkdir(parents=True, exist_ok=True)
        (data_dir / name).write_text(content, encoding="utf-8")
    env = dict(
        os.environ,
        VEASEL_ALLOW_AUTONOMOUS_EXECUTION="1",
        VEASEL_PORT=str(port),
        VEASEL_DATA_DIR=str(data_dir),
        VEASEL_PLUGIN_DIR=str(work / "plugins"),
        VEASEL_MODEL_PROVIDER="openai-compatible",
        VEASEL_MODEL="smoke-model",
        VEASEL_MODEL_API_KEY="veasel-openai-key",
        VEASEL_MODEL_BASE_URL=f"http://127.0.0.1:{provider_port}/v1",
    )
    # {closed_port} resolves to a port bound and released at task time, so
    # the provider (already listening) can never be assigned it.
    env.update({
        key: value.replace("{closed_port}", str(free_port()))
        for key, value in task.get("env", {}).items()
    })
    server = subprocess.Popen(
        [str(veasel), "serve"], env=env,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    trace_path = work / "trajectory.json"
    result_path = work / "result.json"
    try:
        wait_healthy(port, server)
        started = time.monotonic()
        with result_path.open("wb") as out:
            completed = subprocess.run(
                [str(veasel), "run", "--autonomous", "--prompt", task["prompt"],
                 "--workspace", str(workspace), "--trace-file", str(trace_path), "--json"],
                env=env, stdout=out, stderr=subprocess.DEVNULL, timeout=120,
            )
        wall_ms = round((time.monotonic() - started) * 1000, 1)
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()

    result = json.loads(result_path.read_text(encoding="utf-8")) if result_path.exists() else {}
    if task.get("expect_failure"):
        passed = (
            completed.returncode != 0
            and result.get("status") == "failed"
            and bool(result.get("error"))
        )
    else:
        passed = completed.returncode == 0 and result.get("status") == "completed"
    if passed and "expect_response" in task:
        passed = result.get("response") == task["expect_response"]
    if passed and "expect_error_contains" in task:
        passed = task["expect_error_contains"] in (result.get("error") or "")
    if passed and task.get("forbid_in_outputs"):
        outputs = result_path.read_text(encoding="utf-8") if result_path.exists() else ""
        if trace_path.exists():
            outputs += trace_path.read_text(encoding="utf-8")
        passed = all(secret not in outputs for secret in task["forbid_in_outputs"])
    if passed:
        passed = bool(task["check"](workspace))
    if passed and task.get("check_command"):
        passed = run_check_command(task, workspace)
    entry = {
        "id": task["id"],
        "prompt": task["prompt"],
        "check": task["check_description"],
        "passed": passed,
        "wall_ms": wall_ms,
        "status": result.get("status"),
        **trace_metrics(trace_path),
    }
    if not passed:
        entry["error"] = result.get("error")
    return entry


def run_cancel_tool_task(veasel: Path, provider_port: int, task: dict, work: Path) -> dict:
    """Cancel a turn while its shell tool is mid-execution, via the API.

    The scripted command sleeps 5s and only then writes cancel-effect.txt.
    Pass = the operation reaches `cancelled` promptly (not after the full
    sleep) and the effect file never appears, even after outwaiting the
    sleep — i.e. cancellation actually kills the running command instead
    of merely relabelling the finished operation.
    """
    workspace = work / "workspace"
    seed_workspace(task, workspace)

    port = free_port()
    env = dict(
        os.environ,
        VEASEL_ALLOW_AUTONOMOUS_EXECUTION="1",
        VEASEL_PORT=str(port),
        VEASEL_DATA_DIR=str(work / "data"),
        VEASEL_PLUGIN_DIR=str(work / "plugins"),
        VEASEL_MODEL_PROVIDER="openai-compatible",
        VEASEL_MODEL="smoke-model",
        VEASEL_MODEL_API_KEY="veasel-openai-key",
        VEASEL_MODEL_BASE_URL=f"http://127.0.0.1:{provider_port}/v1",
    )
    server = subprocess.Popen(
        [str(veasel), "serve"], env=env,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )

    def api(method: str, path: str, body: dict | None = None, headers: dict | None = None):
        request = Request(
            f"http://127.0.0.1:{port}{path}",
            data=json.dumps(body).encode() if body is not None else None,
            method=method,
            headers={"content-type": "application/json", **(headers or {})},
        )
        with urlopen(request, timeout=10) as response:
            return response.status, json.loads(response.read() or b"{}")

    operation: dict = {}
    cancel_sent = False
    started = time.monotonic()
    wall_ms = -1.0
    error: str | None = None
    try:
        wait_healthy(port, server)
        _, session = api("POST", "/v1/sessions",
                         {"title": "cancel fixture", "directory": str(workspace)})
        session_id = session["id"]
        _, accepted = api(
            "POST", f"/v1/sessions/{session_id}/messages",
            {"content": task["prompt"], "autonomous": True, "non_interactive": True},
            headers={"Prefer": "respond-async"},
        )
        operation_id = accepted["operation_id"]
        deadline = started + 30
        while time.monotonic() < deadline:
            _, operation = api("GET", f"/v1/sessions/{session_id}/operations/{operation_id}")
            status = operation.get("status")
            if status == "running" and not cancel_sent:
                time.sleep(1.5)  # let the shell tool start its 5s sleep
                api("POST", f"/v1/sessions/{session_id}/operations/{operation_id}/cancel", {})
                cancel_sent = True
            if status not in ("queued", "running", "cancelling"):
                break
            time.sleep(0.2)
        wall_ms = round((time.monotonic() - started) * 1000, 1)
        # Outwait the 5s command sleep: a leaked process writes its file now.
        time.sleep(6.5)
    except Exception as exc:  # fixture infrastructure failure must not pass
        error = f"{type(exc).__name__}: {exc}"
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()

    passed = (
        error is None
        and cancel_sent
        and operation.get("status") == "cancelled"
        and bool(task["check"](workspace))
    )
    entry = {
        "id": task["id"],
        "prompt": task["prompt"],
        "check": task["check_description"],
        "passed": passed,
        "wall_ms": wall_ms,
        "status": operation.get("status"),
        "tool_calls": 1,
    }
    if not passed:
        entry["error"] = error or operation.get("error") or f"operation={operation!r}"
    return entry


def run_queue_recovery_task(veasel: Path, provider_port: int, task: dict, work: Path) -> dict:
    """Restart the backend with one running and two queued turns.

    Pass = the running turn (blocked on the held provider response)
    surfaces as `uncertain` with an error and is never replayed, while
    the queued turns resume, complete in FIFO order, and the persisted
    transcript holds exactly their two exchanges in order.
    """
    workspace = work / "workspace"
    seed_workspace(task, workspace)

    port = free_port()
    env = dict(
        os.environ,
        VEASEL_ALLOW_AUTONOMOUS_EXECUTION="1",
        VEASEL_PORT=str(port),
        VEASEL_DATA_DIR=str(work / "data"),
        VEASEL_PLUGIN_DIR=str(work / "plugins"),
        VEASEL_MODEL_PROVIDER="openai-compatible",
        VEASEL_MODEL="smoke-model",
        VEASEL_MODEL_API_KEY="veasel-openai-key",
        VEASEL_MODEL_BASE_URL=f"http://127.0.0.1:{provider_port}/v1",
    )
    provider_base = f"http://127.0.0.1:{provider_port}"

    def api(method: str, path: str, body: dict | None = None, headers: dict | None = None,
            base: str | None = None):
        request = Request(
            f"{base or f'http://127.0.0.1:{port}'}{path}",
            data=json.dumps(body).encode() if body is not None else None,
            method=method,
            headers={"content-type": "application/json", **(headers or {})},
        )
        with urlopen(request, timeout=10) as response:
            return response.status, json.loads(response.read() or b"{}")

    def start_server() -> subprocess.Popen:
        proc = subprocess.Popen(
            [str(veasel), "serve"], env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        wait_healthy(port, proc)
        return proc

    contents = [task["prompt"], "Say hello", "Inspect workspace"]
    expected_messages = [
        ("user", "Say hello"),
        ("assistant", "Provider fixture reply"),
        ("user", "Inspect workspace"),
        ("assistant", "Found workspace-search-sentinel"),
    ]
    finals: dict = {}
    messages: list = []
    pre_restart: list = []
    started = time.monotonic()
    wall_ms = -1.0
    error: str | None = None
    server: subprocess.Popen | None = None
    try:
        server = start_server()
        api("GET", "/hold-slow-response", base=provider_base)
        _, session = api("POST", "/v1/sessions",
                         {"title": "queue recovery fixture", "directory": str(workspace)})
        session_id = session["id"]
        operation_ids = []
        for content in contents:
            _, accepted = api("POST", f"/v1/sessions/{session_id}/messages",
                              {"content": content}, headers={"Prefer": "respond-async"})
            operation_ids.append(accepted["operation_id"])
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            _, first = api("GET", f"/v1/sessions/{session_id}/operations/{operation_ids[0]}")
            if first.get("status") == "running":
                break
            time.sleep(0.1)
        for op_id in operation_ids:
            _, current = api("GET", f"/v1/sessions/{session_id}/operations/{op_id}")
            pre_restart.append(current.get("status"))

        server.terminate()
        server.wait(timeout=10)
        server = start_server()
        api("GET", "/release-slow-response", base=provider_base)

        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            remaining = False
            for op_id in operation_ids:
                _, current = api("GET", f"/v1/sessions/{session_id}/operations/{op_id}")
                finals[op_id] = current
                if current.get("status") in ("queued", "running", "cancelling"):
                    remaining = True
            if not remaining:
                break
            time.sleep(0.25)
        wall_ms = round((time.monotonic() - started) * 1000, 1)
        _, raw_messages = api("GET", f"/v1/sessions/{session_id}/messages")
        messages = [(m.get("role"), m.get("content")) for m in raw_messages]
    except Exception as exc:  # fixture infrastructure failure must not pass
        error = f"{type(exc).__name__}: {exc}"
    finally:
        if server is not None:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()

    passed = (
        error is None
        and pre_restart == ["running", "queued", "queued"]
        and len(finals) == 3
        and finals[operation_ids[0]].get("status") == "uncertain"
        and bool(finals[operation_ids[0]].get("error"))
        and finals[operation_ids[1]].get("status") == "completed"
        and finals[operation_ids[2]].get("status") == "completed"
        and messages == expected_messages
        and bool(task["check"](workspace))
    ) if error is None and len(finals) == 3 else False
    entry = {
        "id": task["id"],
        "prompt": task["prompt"],
        "check": task["check_description"],
        "passed": passed,
        "wall_ms": wall_ms,
        "status": finals[operation_ids[0]].get("status") if len(finals) == 3 else None,
        "tool_calls": 1,
    }
    if not passed:
        entry["error"] = error or f"pre_restart={pre_restart!r} finals={finals!r} messages={messages!r}"
    return entry


def run_worktree_isolation_task(veasel: Path, provider_port: int, task: dict, work: Path) -> dict:
    """Apply an autonomous edit in a linked git worktree, not the checkout.

    The workspace is a real git repo with one commit. A worktree is added
    through the session API on a new branch, then the scripted edit runs
    against the worktree directory. Pass = the edit is present in the
    worktree (uncommitted, on the new branch) while the main checkout is
    byte-identical, on the original branch, and `git status` clean —
    all judged by external git/file state, before vs after.
    """
    workspace = work / "workspace"
    seed_workspace(task, workspace)
    worktree_path = work / "wt-feature"

    def git(cwd: Path, *args: str) -> str:
        completed = subprocess.run(
            ["git", "-c", "user.name=Veasel Fixture",
             "-c", "user.email=fixture@example.invalid", *args],
            cwd=cwd, capture_output=True, text=True, timeout=30,
        )
        if completed.returncode != 0:
            raise RuntimeError(f"git {' '.join(args)} failed: {completed.stderr.strip()[-300:]}")
        return completed.stdout.strip()

    port = free_port()
    env = dict(
        os.environ,
        VEASEL_ALLOW_AUTONOMOUS_EXECUTION="1",
        VEASEL_PORT=str(port),
        VEASEL_DATA_DIR=str(work / "data"),
        VEASEL_PLUGIN_DIR=str(work / "plugins"),
        VEASEL_MODEL_PROVIDER="openai-compatible",
        VEASEL_MODEL="smoke-model",
        VEASEL_MODEL_API_KEY="veasel-openai-key",
        VEASEL_MODEL_BASE_URL=f"http://127.0.0.1:{provider_port}/v1",
    )
    server: subprocess.Popen | None = None
    started = time.monotonic()
    wall_ms = -1.0
    error: str | None = None
    detail: dict = {}
    try:
        if shutil.which("git") is None:
            raise RuntimeError("git executable is not available")
        git(workspace, "init", "-b", "main")
        git(workspace, "add", ".")
        git(workspace, "commit", "-m", "fixture baseline")
        before_status = git(workspace, "status", "--porcelain")
        before_branch = git(workspace, "branch", "--show-current")

        server = subprocess.Popen(
            [str(veasel), "serve"], env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        wait_healthy(port, server)

        def api(method: str, path: str, body: dict | None = None):
            request = Request(
                f"http://127.0.0.1:{port}{path}",
                data=json.dumps(body).encode() if body is not None else None,
                method=method,
                headers={"content-type": "application/json"},
            )
            with urlopen(request, timeout=15) as response:
                return response.status, json.loads(response.read() or b"{}")

        _, session = api("POST", "/v1/sessions",
                         {"title": "worktree fixture", "directory": str(workspace)})
        session_id = session["id"]
        _, created = api("POST", f"/v1/sessions/{session_id}/workspace/git/worktrees",
                         {"path": str(worktree_path), "new_branch": "fixture-feature"})
        detail["created"] = created

        result_path = work / "result.json"
        with result_path.open("wb") as out:
            completed = subprocess.run(
                [str(veasel), "run", "--autonomous", "--prompt", task["prompt"],
                 "--workspace", str(worktree_path),
                 "--trace-file", str(work / "trajectory.json"), "--json"],
                env=env, stdout=out, stderr=subprocess.DEVNULL, timeout=120,
            )
        wall_ms = round((time.monotonic() - started) * 1000, 1)
        result = json.loads(result_path.read_text(encoding="utf-8")) if result_path.exists() else {}
        detail["run_status"] = result.get("status")
        detail["run_error"] = result.get("error")
        detail["returncode"] = completed.returncode

        detail["main_status_after"] = git(workspace, "status", "--porcelain")
        detail["main_branch_after"] = git(workspace, "branch", "--show-current")
        detail["wt_status_after"] = git(worktree_path, "status", "--porcelain")
        detail["wt_branch_after"] = git(worktree_path, "branch", "--show-current")
        detail["wt_contains_greet"] = EXPECTED_GREET in (
            worktree_path / "src" / "main.v").read_text(encoding="utf-8")
        detail["before_status"] = before_status
        detail["before_branch"] = before_branch
    except Exception as exc:  # fixture infrastructure failure must not pass
        error = f"{type(exc).__name__}: {exc}"
    finally:
        if server is not None:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()

    passed = (
        error is None
        and detail.get("before_status") == ""
        and detail.get("before_branch") == "main"
        and detail.get("run_status") == "completed"
        and detail.get("returncode") == 0
        and detail.get("main_status_after") == ""
        and detail.get("main_branch_after") == "main"
        and detail.get("wt_status_after") == "M src/main.v"
        and detail.get("wt_branch_after") == "fixture-feature"
        and detail.get("wt_contains_greet") is True
        and bool(task["check"](workspace))
    )
    entry = {
        "id": task["id"],
        "prompt": task["prompt"],
        "check": task["check_description"],
        "passed": passed,
        "wall_ms": wall_ms,
        "status": detail.get("run_status"),
        "tool_calls": 1,
    }
    if not passed:
        entry["error"] = error or f"detail={detail!r}"
    return entry


SCRIPTED_PROVIDER = Path(__file__).resolve().parent / "scripted_provider.py"


def start_provider(script: Path, work: Path) -> tuple[subprocess.Popen, int, Path]:
    port_file = work / "provider.port"
    log_file = work / "provider.log"
    process = subprocess.Popen(
        [sys.executable, str(script), str(port_file), str(log_file)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    deadline = time.monotonic() + 10
    while not port_file.exists() or not port_file.read_text().strip():
        if time.monotonic() > deadline:
            process.terminate()
            raise TimeoutError(f"provider {script.name} did not become ready")
        time.sleep(0.05)
    return process, int(port_file.read_text().strip()), log_file


def run_opencode_task(opencode: str, provider_port: int, provider_log: Path, task: dict, work: Path) -> dict:
    """Run one fixture through OpenCode against the generic scripted provider.

    The provider answers with the agent's own write tool, so the external
    workspace check is identical to Veasel's. This measures harness
    orchestration only; scripted replies say nothing about model quality.
    """
    workspace = work / "workspace"
    seed_workspace(task, workspace)
    config = {
        "$schema": "https://opencode.ai/config.json",
        "permission": {"edit": "allow", "bash": "allow"},
        "provider": {
            "mock": {
                "npm": "@ai-sdk/openai-compatible",
                "name": "Mock",
                "options": {"baseURL": f"http://127.0.0.1:{provider_port}/v1", "apiKey": "fixture-key"},
                "models": {"smoke-model": {"name": "Smoke Model"}},
            }
        },
    }
    (workspace / "opencode.json").write_text(json.dumps(config, indent=2), encoding="utf-8")
    log_offset = provider_log.stat().st_size if provider_log.exists() else 0
    # OpenCode resolves its project root from $PWD, not getcwd: subprocess
    # cwd= alone leaves $PWD pointing at the caller's directory and the
    # fixture opencode.json is never loaded ("Model unavailable").
    env = dict(os.environ, PWD=str(workspace))
    started = time.monotonic()
    completed = subprocess.run(
        [opencode, "run", "--standalone", "--auto", "-m", "mock/smoke-model", task["prompt"]],
        cwd=workspace, env=env, capture_output=True, timeout=180,
    )
    wall_ms = round((time.monotonic() - started) * 1000, 1)
    requests = 0
    tool_calls = 0
    if provider_log.exists():
        with provider_log.open("rb") as handle:
            handle.seek(log_offset)
            for line in handle:
                requests += 1
                payload = json.loads(line).get("payload", {})
                if (payload.get("messages") or [{}])[-1].get("role") == "tool":
                    tool_calls += 1
    passed = completed.returncode == 0 and bool(task["check"](workspace))
    entry = {
        "id": task["id"],
        "prompt": task["prompt"],
        "check": task["check_description"],
        "passed": passed,
        "wall_ms": wall_ms,
        "status": "completed" if completed.returncode == 0 else "failed",
        "provider_requests": requests,
        "tool_results": tool_calls,
    }
    if not passed:
        tail = (completed.stderr or completed.stdout or b"").decode(errors="replace")[-500:]
        entry["error"] = tail.strip() or f"exit {completed.returncode}, check failed"
    return entry


def provider_stats(provider_log: Path, offset: int) -> tuple[int, int]:
    requests = 0
    tool_results = 0
    if provider_log.exists():
        with provider_log.open("rb") as handle:
            handle.seek(offset)
            for line in handle:
                requests += 1
                payload = json.loads(line).get("payload", {})
                if (payload.get("messages") or [{}])[-1].get("role") == "tool":
                    tool_results += 1
                items = payload.get("input") or []
                if any(isinstance(i, dict) and i.get("type") == "function_call_output" for i in items):
                    tool_results += 1
    return requests, tool_results


def run_pi_task(pi: str, provider_port: int, provider_log: Path, task: dict, work: Path) -> dict:
    """Run one fixture through Pi (pi-mono) against the scripted provider.

    Pi is configured through an isolated PI_CODING_AGENT_DIR so the user's
    real Pi configuration is never touched. Same external check as Veasel.
    """
    workspace = work / "workspace"
    seed_workspace(task, workspace)
    agent_dir = work / "pi-agent"
    agent_dir.mkdir()
    models = {
        "providers": {
            "mock": {
                "baseUrl": f"http://127.0.0.1:{provider_port}/v1",
                "api": "openai-completions",
                "apiKey": "fixture-key",
                "models": [{"id": "smoke-model", "name": "Smoke Model"}],
            }
        }
    }
    (agent_dir / "models.json").write_text(json.dumps(models, indent=2), encoding="utf-8")
    log_offset = provider_log.stat().st_size if provider_log.exists() else 0
    env = dict(os.environ, PWD=str(workspace), PI_CODING_AGENT_DIR=str(agent_dir))
    started = time.monotonic()
    completed = subprocess.run(
        [pi, "-p", "--no-session", "--provider", "mock", "--model", "smoke-model", task["prompt"]],
        cwd=workspace, env=env, capture_output=True, timeout=180,
    )
    wall_ms = round((time.monotonic() - started) * 1000, 1)
    requests, tool_results = provider_stats(provider_log, log_offset)
    passed = completed.returncode == 0 and bool(task["check"](workspace))
    entry = {
        "id": task["id"],
        "prompt": task["prompt"],
        "check": task["check_description"],
        "passed": passed,
        "wall_ms": wall_ms,
        "status": "completed" if completed.returncode == 0 else "failed",
        "provider_requests": requests,
        "tool_results": tool_results,
    }
    if not passed:
        tail = (completed.stderr or completed.stdout or b"").decode(errors="replace")[-500:]
        entry["error"] = tail.strip() or f"exit {completed.returncode}, check failed"
    return entry


RESPONSES_PROVIDER = Path(__file__).resolve().parent / "responses_provider.py"


def run_codex_task(codex: str, provider_port: int, provider_log: Path, task: dict, work: Path) -> dict:
    """Run one fixture through Codex against the scripted Responses provider.

    Codex is configured through an isolated CODEX_HOME. Its scripted tool is
    `exec_command` (shell), not its freeform apply_patch tool: the external
    check is identical, but this measures shell-tool orchestration only.
    """
    workspace = work / "workspace"
    seed_workspace(task, workspace)
    codex_home = work / "codex-home"
    codex_home.mkdir()
    config = (
        'model = "smoke-model"\nmodel_provider = "mock"\n'
        'approval_policy = "never"\nsandbox_mode = "workspace-write"\n\n'
        "[model_providers.mock]\nname = \"Mock\"\n"
        f'base_url = "http://127.0.0.1:{provider_port}/v1"\n'
        'wire_api = "responses"\nenv_key = "FIXTURE_API_KEY"\n'
    )
    (codex_home / "config.toml").write_text(config, encoding="utf-8")
    log_offset = provider_log.stat().st_size if provider_log.exists() else 0
    env = dict(os.environ, PWD=str(workspace), CODEX_HOME=str(codex_home), FIXTURE_API_KEY="fixture-key")
    started = time.monotonic()
    completed = subprocess.run(
        [codex, "exec", "--skip-git-repo-check", task["prompt"]],
        cwd=workspace, env=env, capture_output=True, timeout=180,
        stdin=subprocess.DEVNULL,
    )
    wall_ms = round((time.monotonic() - started) * 1000, 1)
    requests, tool_results = provider_stats(provider_log, log_offset)
    passed = completed.returncode == 0 and bool(task["check"](workspace))
    entry = {
        "id": task["id"],
        "prompt": task["prompt"],
        "check": task["check_description"],
        "passed": passed,
        "wall_ms": wall_ms,
        "status": "completed" if completed.returncode == 0 else "failed",
        "provider_requests": requests,
        "tool_results": tool_results,
    }
    if not passed:
        tail = (completed.stderr or completed.stdout or b"").decode(errors="replace")[-500:]
        entry["error"] = tail.strip() or f"exit {completed.returncode}, check failed"
    return entry


def run_mini_task(provider_port: int, provider_log: Path, task: dict, work: Path) -> dict:
    """Run one fixture through mini-SWE-agent 2.x against the scripted provider.

    Driven via `uvx --with mcp --from mini-swe-agent==2.4.6 mini` (uv-managed,
    nothing installed into the project; the version is pinned and `mcp` is
    injected because the unpinned uvx resolution drifted into a litellm build
    that imports `mcp.types` without declaring the `mcp` package).
    MSWEA_CONFIGURED skips its interactive first-run setup
    and MSWEA_COST_TRACKING=ignore_errors keeps the unknown fixture model out
    of litellm's pricing registry. Its only tool is bash, so the scripted
    provider answers with a bash tool call. Isolated MSWEA_GLOBAL_CONFIG_DIR.
    """
    workspace = work / "workspace"
    seed_workspace(task, workspace)
    global_dir = work / "mini-global"
    global_dir.mkdir()
    (global_dir / ".env").write_text("OPENAI_API_KEY=fixture-key\n", encoding="utf-8")
    log_offset = provider_log.stat().st_size if provider_log.exists() else 0
    env = dict(
        os.environ,
        PWD=str(workspace),
        MSWEA_CONFIGURED="1",
        MSWEA_COST_TRACKING="ignore_errors",
        MSWEA_GLOBAL_CONFIG_DIR=str(global_dir),
        OPENAI_BASE_URL=f"http://127.0.0.1:{provider_port}/v1",
        OPENAI_API_KEY="fixture-key",
    )
    started = time.monotonic()
    completed = subprocess.run(
        ["uvx", "--with", "mcp", "--from", "mini-swe-agent==2.4.6", "mini", "-y", "--exit-immediately", "-m", "openai/smoke-model", "-t", task["prompt"]],
        cwd=workspace, env=env, capture_output=True, timeout=300,
        stdin=subprocess.DEVNULL,
    )
    wall_ms = round((time.monotonic() - started) * 1000, 1)
    requests, tool_results = provider_stats(provider_log, log_offset)
    passed = completed.returncode == 0 and bool(task["check"](workspace))
    entry = {
        "id": task["id"],
        "prompt": task["prompt"],
        "check": task["check_description"],
        "passed": passed,
        "wall_ms": wall_ms,
        "status": "completed" if completed.returncode == 0 else "failed",
        "provider_requests": requests,
        "tool_results": tool_results,
    }
    if not passed:
        tail = (completed.stderr or completed.stdout or b"").decode(errors="replace")[-500:]
        entry["error"] = tail.strip() or f"exit {completed.returncode}, check failed"
    return entry


def dispatch_task(args, veasel, provider_port, provider_log, task, task_work) -> dict:
    if args.agent == "veasel":
        if task.get("kind") == "cancel_tool":
            return run_cancel_tool_task(veasel, provider_port, task, task_work)
        if task.get("kind") == "queue_recovery":
            return run_queue_recovery_task(veasel, provider_port, task, task_work)
        if task.get("kind") == "worktree_isolation":
            return run_worktree_isolation_task(veasel, provider_port, task, task_work)
        return run_task(veasel, provider_port, task, task_work)
    if args.agent == "pi":
        return run_pi_task(args.pi, provider_port, provider_log, task, task_work)
    if args.agent == "codex":
        return run_codex_task(args.codex, provider_port, provider_log, task, task_work)
    if args.agent == "mini":
        return run_mini_task(provider_port, provider_log, task, task_work)
    return run_opencode_task(args.opencode, provider_port, provider_log, task, task_work)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--veasel", help="path to the veasel binary under test")
    parser.add_argument("--agent", choices=("veasel", "opencode", "pi", "codex", "mini"), default="veasel")
    parser.add_argument("--opencode", default="opencode", help="opencode executable (agent=opencode)")
    parser.add_argument("--pi", default="pi", help="pi executable (agent=pi)")
    parser.add_argument("--codex", default="codex", help="codex executable (agent=codex)")
    parser.add_argument("--report", help="write the JSON report to this path")
    parser.add_argument("--startup-runs", type=int, default=5,
                        help="cold `veasel serve` spawns sampled for the report's startup metrics (0 disables; veasel agent only)")
    parser.add_argument("--keep", action="store_true", help="keep the temporary workspace")
    args = parser.parse_args()

    if args.agent == "veasel" and not args.veasel:
        parser.error("--veasel is required for --agent veasel")
    veasel = Path(args.veasel).resolve() if args.veasel else None
    if veasel is not None and not veasel.exists():
        print(f"veasel binary not found: {veasel}", file=sys.stderr)
        return 2

    work_root = Path(tempfile.mkdtemp(prefix="veasel-deterministic-"))
    script = MOCK_PROVIDER if args.agent == "veasel" else RESPONSES_PROVIDER if args.agent == "codex" else SCRIPTED_PROVIDER
    try:
        provider, provider_port, provider_log = start_provider(script, work_root)
    except TimeoutError as error:
        print(str(error), file=sys.stderr)
        return 2
    try:
        results = []
        # Competitor adapters run only tasks explicitly marked competitor:
        # the generic scripted providers drive a single unconditional write,
        # so anything else would pass or fail for protocol reasons unrelated
        # to the task's stated oracle. Skipped tasks are reported, never
        # silently dropped from the count.
        tasks = TASKS if args.agent == "veasel" else [t for t in TASKS if t.get("competitor")]
        skipped = [] if args.agent == "veasel" else [
            t["id"] for t in TASKS if not t.get("competitor")
        ]
        if skipped:
            print(f"SKIPPED {len(skipped)}/{len(TASKS)} tasks for agent={args.agent}: "
                  f"generic scripted provider drives only competitor-marked tasks: "
                  f"{', '.join(skipped)}")
        for index, task in enumerate(tasks):
            task_work = work_root / f"task-{index}"
            task_work.mkdir()
            try:
                entry = dispatch_task(args, veasel, provider_port, provider_log, task, task_work)
            except subprocess.TimeoutExpired:
                entry = {
                    "id": task["id"], "prompt": task["prompt"], "check": task["check_description"],
                    "passed": False, "wall_ms": -1, "status": "timeout",
                    "error": "agent subprocess timed out",
                }
            results.append(entry)
            print(f"{task['id']}: {'PASS' if results[-1]['passed'] else 'FAIL'} "
                  f"({results[-1]['wall_ms']} ms, {results[-1].get('tool_calls', results[-1].get('tool_results'))} tool calls)")
        startup = None
        if args.agent == "veasel" and args.startup_runs > 0:
            try:
                startup = measure_startup(veasel, args.startup_runs, work_root)
                print(f"startup: p50 {startup['p50_ms']} ms, p95 {startup['p95_ms']} ms "
                      f"over {startup['runs']} cold spawns (rss p50 {startup['rss_kib_p50']} KiB)")
            except (RuntimeError, TimeoutError, OSError) as error:
                # A server that cannot start already failed every task
                # above; keep the task report instead of masking it.
                startup = {"error": str(error)}
                print(f"startup: FAILED ({error})")
    finally:
        provider.terminate()
        if not args.keep:
            shutil.rmtree(work_root, ignore_errors=True)
        else:
            print(f"kept workdir: {work_root}")

    report = {
        "schema": "veasel-deterministic-fixtures/1",
        "agent": args.agent,
        "provider": f"{script.name} (deterministic, OpenAI-compatible)",
        "model": "smoke-model (scripted replies; no real model)",
        "tasks": results,
        "passed": sum(1 for r in results if r["passed"]),
        "total": len(results),
        "skipped": skipped,
    }
    if veasel is not None:
        report["binary"] = veasel.name
        report["binary_sha256"] = hashlib.sha256(veasel.read_bytes()).hexdigest()
    if startup is not None:
        report["startup"] = startup
    if args.report:
        Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(f"report: {args.report}")
    return 0 if report["passed"] == report["total"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
