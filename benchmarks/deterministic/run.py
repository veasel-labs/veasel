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
from urllib.request import urlopen

REPO_ROOT = Path(__file__).resolve().parents[2]
MOCK_PROVIDER = REPO_ROOT / "scripts" / "mock-provider.py"

INITIAL_MAIN_V = "module fixture\n\n// workspace-search-sentinel\n"
EXPECTED_GREET = "fn greet(name string) string {"


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


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
    (workspace / "src").mkdir(parents=True)
    (workspace / "src" / "main.v").write_text(INITIAL_MAIN_V, encoding="utf-8")

    port = free_port()
    data_dir = work / "data"
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
    passed = completed.returncode == 0 and result.get("status") == "completed"
    if passed and "expect_response" in task:
        passed = result.get("response") == task["expect_response"]
    if passed:
        passed = bool(task["check"](workspace))
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
    (workspace / "src").mkdir(parents=True)
    (workspace / "src" / "main.v").write_text(INITIAL_MAIN_V, encoding="utf-8")
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
    (workspace / "src").mkdir(parents=True)
    (workspace / "src" / "main.v").write_text(INITIAL_MAIN_V, encoding="utf-8")
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
    (workspace / "src").mkdir(parents=True)
    (workspace / "src" / "main.v").write_text(INITIAL_MAIN_V, encoding="utf-8")
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

    Driven via `uvx --from mini-swe-agent mini` (uv-managed, nothing installed
    into the project). MSWEA_CONFIGURED skips its interactive first-run setup
    and MSWEA_COST_TRACKING=ignore_errors keeps the unknown fixture model out
    of litellm's pricing registry. Its only tool is bash, so the scripted
    provider answers with a bash tool call. Isolated MSWEA_GLOBAL_CONFIG_DIR.
    """
    workspace = work / "workspace"
    (workspace / "src").mkdir(parents=True)
    (workspace / "src" / "main.v").write_text(INITIAL_MAIN_V, encoding="utf-8")
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
        ["uvx", "--from", "mini-swe-agent", "mini", "-y", "--exit-immediately", "-m", "openai/smoke-model", "-t", task["prompt"]],
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
        tasks = TASKS if args.agent == "veasel" else [t for t in TASKS if "expect_response" not in t]
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
    }
    if veasel is not None:
        report["binary"] = veasel.name
        report["binary_sha256"] = hashlib.sha256(veasel.read_bytes()).hexdigest()
    if args.report:
        Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(f"report: {args.report}")
    return 0 if report["passed"] == report["total"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
