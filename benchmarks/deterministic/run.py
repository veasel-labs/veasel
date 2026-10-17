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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--veasel", required=True, help="path to the veasel binary under test")
    parser.add_argument("--report", help="write the JSON report to this path")
    parser.add_argument("--keep", action="store_true", help="keep the temporary workspace")
    args = parser.parse_args()

    veasel = Path(args.veasel).resolve()
    if not veasel.exists():
        print(f"veasel binary not found: {veasel}", file=sys.stderr)
        return 2

    work_root = Path(tempfile.mkdtemp(prefix="veasel-deterministic-"))
    provider_out = work_root / "provider.port"
    provider = subprocess.Popen(
        [sys.executable, str(MOCK_PROVIDER), str(provider_out)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        deadline = time.monotonic() + 10
        while not provider_out.exists() or not provider_out.read_text().strip():
            if time.monotonic() > deadline:
                print("mock provider did not become ready", file=sys.stderr)
                return 2
            time.sleep(0.05)
        provider_port = int(provider_out.read_text().strip())

        results = []
        for index, task in enumerate(TASKS):
            task_work = work_root / f"task-{index}"
            task_work.mkdir()
            results.append(run_task(veasel, provider_port, task, task_work))
            print(f"{task['id']}: {'PASS' if results[-1]['passed'] else 'FAIL'} "
                  f"({results[-1]['wall_ms']} ms, {results[-1].get('tool_calls')} tool calls)")
    finally:
        provider.terminate()
        if not args.keep:
            shutil.rmtree(work_root, ignore_errors=True)
        else:
            print(f"kept workdir: {work_root}")

    report = {
        "schema": "veasel-deterministic-fixtures/1",
        "agent": "veasel",
        "binary": veasel.name,
        "binary_sha256": hashlib.sha256(veasel.read_bytes()).hexdigest(),
        "provider": "scripts/mock-provider.py (deterministic, OpenAI-compatible)",
        "model": "smoke-model (scripted replies; no real model)",
        "tasks": results,
        "passed": sum(1 for r in results if r["passed"]),
        "total": len(results),
    }
    if args.report:
        Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(f"report: {args.report}")
    return 0 if report["passed"] == report["total"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
