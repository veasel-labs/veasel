#!/usr/bin/env python3
"""Preflight and run a versioned, local-model coding task case."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent
GIB = 1024**3


def load_case(path: Path) -> tuple[dict[str, Any], Path, str]:
    case = json.loads(path.read_text())
    prompt_path = path.parent / case["prompt_file"]
    prompt = prompt_path.read_text()
    digest = hashlib.sha256(prompt.encode()).hexdigest()
    return case, prompt_path, digest


def available_resources() -> tuple[int, int]:
    values: dict[str, int] = {}
    for line in Path("/proc/meminfo").read_text().splitlines():
        key, raw = line.split(":", 1)
        if key in {"MemAvailable", "SwapFree"}:
            values[key] = int(raw.strip().split()[0]) * 1024
    return values["MemAvailable"], values["SwapFree"]


def restricted_environment(source: dict[str, str] | None = None) -> dict[str, str]:
    source = os.environ if source is None else source
    allowed = {"PATH", "HOME", "LANG", "LC_ALL", "TERM", "TMPDIR", "SSL_CERT_FILE", "SSL_CERT_DIR"}
    return {key: value for key, value in source.items() if key in allowed or key.startswith("LC_")}


def free_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.bind(("127.0.0.1", 0))
        return int(server.getsockname()[1])


def private_directory(path: Path) -> Path:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.chmod(0o700)
    return path


def model_digest(base_url: str, model: str) -> str:
    request = urllib.request.Request(base_url.rstrip("/") + "/api/tags")
    with urllib.request.urlopen(request, timeout=3) as response:
        tags = json.load(response).get("models", [])
    matches = [item for item in tags if item.get("name") == model]
    if len(matches) != 1:
        raise RuntimeError(f"Ollama did not report exactly one installed {model!r} tag")
    return str(matches[0].get("digest", ""))


def ollama_version(base_url: str) -> str:
    request = urllib.request.Request(base_url.rstrip("/") + "/api/version")
    with urllib.request.urlopen(request, timeout=3) as response:
        return str(json.load(response).get("version", ""))


def gpu_info() -> dict[str, Any]:
    output = subprocess.check_output(
        ["nvidia-smi", "--query-gpu=name,memory.total", "--format=csv,noheader,nounits"],
        text=True,
    ).splitlines()[0]
    name, memory_mib = output.rsplit(",", 1)
    return {"name": name.strip(), "memory_mib": int(memory_mib.strip())}


def configured_model(data_dir: Path) -> dict[str, Any]:
    settings = json.loads((data_dir / "model-settings.json").read_text())
    provider = settings.get("active_provider", "")
    profile = settings.get("profiles", {}).get(provider, {})
    return {
        "provider": provider,
        "model": profile.get("model", ""),
        "base_url": profile.get("base_url", ""),
        "max_output_tokens": profile.get("max_output_tokens", 0),
        "api_key_saved": bool(profile.get("api_key", "")),
    }


def open_code_version(binary: str) -> str:
    return subprocess.check_output([binary, "--version"], text=True, stderr=subprocess.DEVNULL).strip()


def open_code_config(case: dict[str, Any]) -> dict[str, Any]:
    model_name = case["model"]["name"]
    model_id = case["comparators"]["opencode_model"]
    config = {
        "$schema": "https://opencode.ai/config.json",
        "model": model_id,
        "providers": {
            "ollama": {
                "settings": {"baseURL": case["provider_config"]["base_url"]},
                "models": {
                    model_name: {
                        "name": model_name,
                        "limit": {
                            "context": case["model"]["context_tokens"],
                            "output": case["model"]["output_tokens"],
                        },
                    },
                },
            },
        },
    }
    if config["model"] != f"ollama/{model_name}":
        raise ValueError("OpenCode model ID must point to the pinned local Ollama model")
    return config


def prepare_open_code_config(case: dict[str, Any], data_dir: Path) -> Path:
    config_path = data_dir / "benchmark-opencode.json"
    content = json.dumps(open_code_config(case), indent=2) + "\n"
    if config_path.exists() and config_path.read_text() != content:
        raise RuntimeError(f"Refusing to overwrite a different OpenCode config: {config_path}")
    private_directory(data_dir)
    config_path.write_text(content)
    config_path.chmod(0o600)
    return config_path


def managed_open_code_config_paths() -> list[Path]:
    if sys.platform == "darwin":
        root = Path("/Library/Application Support/opencode")
    elif os.name == "nt":
        root = Path(os.environ.get("ProgramData", r"C:\\ProgramData")) / "opencode"
    else:
        root = Path("/etc/opencode")
    return [root / name for name in ("opencode.json", "opencode.jsonc") if (root / name).is_file()]


def project_open_code_config_paths(workspace: Path, revision: str) -> list[str]:
    paths = git(workspace, "ls-tree", "-r", "--name-only", revision).splitlines()
    return [path for path in paths if Path(path).name in {"opencode.json", "opencode.jsonc"}
            or path.startswith(".opencode/")]


def build_command(agent: str, binary: str, case: dict[str, Any], workspace: Path,
                  prompt: str, trace_path: Path) -> list[str]:
    if agent == "veasel":
        return [binary, "run", "--autonomous", "--prompt", prompt,
                "--workspace", str(workspace), "--timeout", str(case["budgets"]["wall_seconds"]),
                "--trace-file", str(trace_path), "--json"]
    command = [binary, "run", "--standalone", "--model", case["comparators"]["opencode_model"],
               "--agent", case["comparators"]["opencode_agent"], "--dir", str(workspace),
               "--format", "json", prompt]
    if case["comparators"]["opencode_auto_approve"]:
        command.insert(3, "--auto")
    return command


def git(workspace: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(workspace), *args], text=True).strip()


def preflight(case_path: Path, workspace: Path, ollama_url: str, data_dir: Path, agent: str = "veasel", agent_binary: str = "opencode") -> dict[str, Any]:
    case, _prompt_path, prompt_hash = load_case(case_path)
    expected = case["model"]["digest"]
    available, swap = available_resources()
    checks: list[dict[str, Any]] = []

    def check(name: str, ok: bool, actual: Any, required: Any) -> None:
        checks.append({"name": name, "passed": ok, "actual": actual, "required": required})

    check("prompt_sha256", prompt_hash == case["prompt_sha256"], prompt_hash, case["prompt_sha256"])
    origin = git(workspace, "remote", "get-url", "origin")
    check("repository", origin.rstrip("/").removesuffix(".git") == case["repository"].removesuffix(".git"), origin, case["repository"])
    revision = git(workspace, "rev-parse", "HEAD")
    check("base_commit", revision == case["base_commit"], revision, case["base_commit"])
    dirty = git(workspace, "status", "--porcelain")
    check("clean_workspace", not dirty, not bool(dirty), True)
    expected_ollama_url = case["provider_config"]["base_url"].rstrip("/").removesuffix("/v1")
    actual_ollama_url = ollama_url.rstrip("/")
    check("ollama_endpoint", actual_ollama_url == expected_ollama_url, actual_ollama_url, expected_ollama_url)
    if agent == "veasel":
        expected_config = case["provider_config"]
        try:
            actual_config = configured_model(data_dir)
            safe_actual = {key: actual_config[key] for key in expected_config}
            check("veasel_model_config", safe_actual == expected_config, safe_actual, expected_config)
        except (OSError, KeyError, json.JSONDecodeError) as exc:
            check("veasel_model_config", False, type(exc).__name__, expected_config)
    else:
        expected_version = case["comparators"]["opencode_version"]
        expected_model_id = case["comparators"]["opencode_model"]
        try:
            generated_config = open_code_config(case)
            config_path = data_dir / "benchmark-opencode.json"
            expected_config_text = json.dumps(generated_config, indent=2) + "\n"
            config_matches = not config_path.exists() or config_path.read_text() == expected_config_text
            check("opencode_model_config", generated_config["model"] == expected_model_id and config_matches,
                  generated_config["model"], expected_model_id)
        except (KeyError, OSError, ValueError) as exc:
            check("opencode_model_config", False, type(exc).__name__, expected_model_id)
        try:
            project_configs = project_open_code_config_paths(workspace, revision)
            check("opencode_project_config", not project_configs, project_configs, [])
        except (OSError, subprocess.CalledProcessError) as exc:
            check("opencode_project_config", False, type(exc).__name__, [])
        managed_configs = managed_open_code_config_paths()
        check("opencode_managed_config", not managed_configs, [str(path) for path in managed_configs], [])
        binary = shutil.which(agent_binary)
        if not binary:
            check("opencode_version", False, "not_installed", expected_version)
        else:
            try:
                actual_version = open_code_version(binary)
                check("opencode_version", actual_version == expected_version, actual_version, expected_version)
            except (OSError, subprocess.CalledProcessError) as exc:
                check("opencode_version", False, type(exc).__name__, expected_version)
    try:
        actual_digest = model_digest(ollama_url, case["model"]["name"])
        check("model_digest", actual_digest == expected, actual_digest, expected)
    except (OSError, RuntimeError, urllib.error.URLError, json.JSONDecodeError) as exc:
        check("model_digest", False, type(exc).__name__, expected)
    expected_ollama = case.get("runtime", {}).get("ollama_version")
    if expected_ollama:
        try:
            actual_ollama = ollama_version(ollama_url)
            check("ollama_version", actual_ollama == expected_ollama, actual_ollama, expected_ollama)
        except (OSError, urllib.error.URLError, json.JSONDecodeError) as exc:
            check("ollama_version", False, type(exc).__name__, expected_ollama)
    expected_gpu = case.get("runtime", {}).get("gpu")
    if expected_gpu:
        try:
            actual_gpu = gpu_info()
            check("gpu", actual_gpu == expected_gpu, actual_gpu, expected_gpu)
        except (OSError, subprocess.CalledProcessError, IndexError, ValueError) as exc:
            check("gpu", False, type(exc).__name__, expected_gpu)
    min_memory = case["budgets"]["minimum_available_memory_bytes"]
    min_swap = case["budgets"]["minimum_free_swap_bytes"]
    check("available_memory", available >= min_memory, available, min_memory)
    check("free_swap", swap >= min_swap, swap, min_swap)
    return {
        "schema": "veasel.real-task-preflight.v1",
        "case_id": case["id"],
        "agent": agent,
        "passed": all(item["passed"] for item in checks),
        "checks": checks,
        "resources_bytes": {"available_memory": available, "free_swap": swap},
    }


def run_case(args: argparse.Namespace) -> int:
    case, _prompt_path, _prompt_hash = load_case(args.case)
    workspace = args.workspace.resolve()
    data_dir = args.data_dir.resolve()
    agent_binary_arg = args.veasel if args.agent == "veasel" else args.opencode
    result = preflight(args.case, workspace, args.ollama_url, data_dir, args.agent, agent_binary_arg)
    if not result["passed"]:
        print(json.dumps(result, indent=2))
        return 2
    if not args.sandbox_confirmed:
        print("Refusing autonomous run without --sandbox-confirmed inside a disposable sandbox.", file=sys.stderr)
        return 2

    private_directory(data_dir)

    agent_binary = shutil.which(agent_binary_arg)
    if not agent_binary:
        print(f"{args.agent} executable not found: {agent_binary_arg}", file=sys.stderr)
        return 2
    artifact_dir = args.artifacts.resolve()
    if artifact_dir.exists() and any(artifact_dir.iterdir()):
        print(f"Refusing to overwrite non-empty artifact directory: {artifact_dir}", file=sys.stderr)
        return 2
    artifact_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    artifact_dir.chmod(0o700)
    trace_path = artifact_dir / "trajectory.private.json"
    stdout_path = artifact_dir / "stdout.private.log"
    stderr_path = artifact_dir / "stderr.private.log"
    env = restricted_environment()
    env["HOME"] = str(private_directory(data_dir / "home"))
    prompt = (args.case.parent / case["prompt_file"]).read_text()
    if args.agent == "veasel":
        env["VEASEL_DATA_DIR"] = str(data_dir)
        plugin_dir = private_directory(data_dir / "plugins")
        env["VEASEL_PLUGIN_DIR"] = str(plugin_dir)
        env["VEASEL_PORT"] = str(free_loopback_port())
        env["VEASEL_MODEL_CONTEXT_TOKENS"] = str(case["model"]["context_tokens"])
        env["VEASEL_MODEL_MAX_OUTPUT_TOKENS"] = str(case["model"]["output_tokens"])
        env["VEASEL_ALLOW_AUTONOMOUS_EXECUTION"] = "1"
        command = build_command(args.agent, agent_binary, case, workspace, prompt, trace_path)
    else:
        opencode_config = prepare_open_code_config(case, data_dir)
        env["OPENCODE_CONFIG"] = str(opencode_config)
        for key, name in (("XDG_CONFIG_HOME", "xdg-config"), ("XDG_DATA_HOME", "xdg-data"), ("XDG_CACHE_HOME", "xdg-cache")):
            env[key] = str(private_directory(data_dir / name))
        command = build_command(args.agent, agent_binary, case, workspace, prompt, trace_path)
    started = time.monotonic()
    min_memory = case["budgets"]["minimum_available_memory_bytes"]
    min_swap = case["budgets"]["minimum_free_swap_bytes"]
    samples: list[dict[str, int]] = []
    outcome = "completed"
    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        stdout_path.chmod(0o600)
        stderr_path.chmod(0o600)
        process = subprocess.Popen(command, cwd=workspace, env=env, stdout=stdout, stderr=stderr, start_new_session=True)
        while process.poll() is None:
            available, swap = available_resources()
            samples.append({"elapsed_ms": int((time.monotonic() - started) * 1000), "available_memory": available, "free_swap": swap})
            if available < min_memory or swap < min_swap:
                outcome = "resource_aborted"
                try:
                    os.killpg(process.pid, signal.SIGINT)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                break
            if time.monotonic() - started >= case["budgets"]["wall_seconds"]:
                outcome = "timeout"
                try:
                    os.killpg(process.pid, signal.SIGINT)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                break
            time.sleep(1)
        return_code = process.wait()
    if outcome == "completed" and return_code != 0:
        outcome = "agent_error"
    report = {
        "schema": "veasel.real-task-attempt.v1",
        "case_id": case["id"],
        "base_commit": case["base_commit"],
        "prompt_sha256": case["prompt_sha256"],
        "model": case["model"],
        "provider_config": case["provider_config"],
        "runtime": case["runtime"],
        "permissions": case["permissions"],
        "host": {"platform": platform.platform(), "machine": platform.machine(), "processor": platform.processor()},
        "agent": args.agent,
        "agent_version": open_code_version(agent_binary) if args.agent == "opencode" else subprocess.check_output([agent_binary, "--version"], text=True).strip(),
        "preflight": result,
        "outcome": outcome,
        "return_code": return_code,
        "wall_ms": int((time.monotonic() - started) * 1000),
        "resource_samples": samples,
        "artifacts": {"trace": trace_path.name if args.agent == "veasel" else None,
                      "stdout": stdout_path.name, "stderr": stderr_path.name},
        "score": "unscored; externally verify the patch and task oracle",
    }
    output = artifact_dir / "attempt.json"
    output.write_text(json.dumps(report, indent=2) + "\n")
    output.chmod(0o600)
    print(output)
    return 0 if outcome == "completed" else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="action", required=True)
    for action in ("preflight", "run"):
        sub = subparsers.add_parser(action)
        sub.add_argument("--case", type=Path, default=ROOT / "cases/website-173/case.json")
        sub.add_argument("--workspace", type=Path, required=True)
        sub.add_argument("--agent", choices=("veasel", "opencode"), default="veasel")
        sub.add_argument("--ollama-url", default="http://127.0.0.1:11435")
        sub.add_argument("--data-dir", type=Path, required=True, help="isolated agent state directory inside the benchmark sandbox")
        sub.add_argument("--veasel", default="veasel")
        sub.add_argument("--opencode", default="opencode")
        if action == "run":
            sub.add_argument("--artifacts", type=Path, required=True)
            sub.add_argument("--sandbox-confirmed", action="store_true", help="confirm this runs inside a disposable, externally isolated task sandbox")
    args = parser.parse_args()
    try:
        if args.action == "preflight":
            agent_binary = args.veasel if args.agent == "veasel" else args.opencode
            report = preflight(args.case, args.workspace.resolve(), args.ollama_url, args.data_dir.resolve(), args.agent, agent_binary)
            print(json.dumps(report, indent=2))
            return 0 if report["passed"] else 2
        return run_case(args)
    except (OSError, subprocess.CalledProcessError, KeyError, json.JSONDecodeError) as exc:
        print(f"preflight error: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
