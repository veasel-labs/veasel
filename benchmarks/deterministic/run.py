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
        "id": "greeting-reply",
        "prompt": "Say hello",
        "check": lambda ws: True,  # scored from the run result below
        "check_description": "headless run completes with the fixture reply",
        "expect_response": "Provider fixture reply",
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--veasel", help="path to the veasel binary under test")
    parser.add_argument("--agent", choices=("veasel", "opencode"), default="veasel")
    parser.add_argument("--opencode", default="opencode", help="opencode executable (agent=opencode)")
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
    script = MOCK_PROVIDER if args.agent == "veasel" else SCRIPTED_PROVIDER
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
            if args.agent == "veasel":
                results.append(run_task(veasel, provider_port, task, task_work))
            else:
                results.append(run_opencode_task(args.opencode, provider_port, provider_log, task, task_work))
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
