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
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parent
GIB = 1024**3
PINNED_VEASEL_MAX_MODEL_ROUNDS = 28
PINNED_PROVIDER_HTTP_ATTEMPTS_PER_ROUND = 3


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


def parse_proc_stat(raw: str, page_size: int) -> tuple[int, int, int]:
    """Return parent PID, process CPU ticks, and resident bytes from procfs."""
    closing_paren = raw.rfind(")")
    if closing_paren < 0:
        raise ValueError("process stat is missing its command terminator")
    fields = raw[closing_paren + 1 :].split()
    if len(fields) <= 21:
        raise ValueError("process stat is incomplete")
    parent_pid = int(fields[1])
    cpu_ticks = int(fields[11]) + int(fields[12])
    resident_bytes = int(fields[21]) * page_size
    return parent_pid, cpu_ticks, resident_bytes


def process_tree_resources(root_pid: int, proc_root: Path = Path("/proc")) -> dict[str, int] | None:
    """Sample RSS and CPU time for an agent process and its descendants on Linux."""
    if not proc_root.is_dir():
        return None
    page_size = os.sysconf("SC_PAGE_SIZE")
    processes: dict[int, tuple[int, int, int]] = {}
    for stat_path in proc_root.glob("[0-9]*/stat"):
        try:
            pid = int(stat_path.parent.name)
            processes[pid] = parse_proc_stat(stat_path.read_text(), page_size)
        except (OSError, ValueError):
            continue
    if root_pid not in processes:
        return None
    descendants = {root_pid}
    while True:
        children = {pid for pid, (parent, _cpu, _rss) in processes.items() if parent in descendants}
        new_descendants = children - descendants
        if not new_descendants:
            break
        descendants.update(new_descendants)
    return {
        "process_count": len(descendants),
        "cpu_time_ms": int(sum(processes[pid][1] for pid in descendants) * 1000 / os.sysconf("SC_CLK_TCK")),
        "rss_bytes": sum(processes[pid][2] for pid in descendants),
    }


def gpu_memory_used_mib() -> list[int] | None:
    """Return device-wide used VRAM by GPU; this includes unrelated GPU clients."""
    try:
        output = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
            text=True,
            timeout=2,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None
    try:
        values = [int(line.strip()) for line in output.splitlines() if line.strip()]
    except ValueError:
        return None
    return values or None


def resource_measurement_summary(samples: list[dict[str, Any]]) -> dict[str, Any]:
    def sampled_maximum(key: str) -> int | None:
        values = [sample[key] for sample in samples if isinstance(sample.get(key), int)]
        return max(values) if values else None

    gpu_samples = [sample.get("gpu_memory_used_mib") for sample in samples]
    device_count = max((len(value) for value in gpu_samples if isinstance(value, list)), default=0)
    gpu_maxima = [
        max(value[index] for value in gpu_samples if isinstance(value, list) and len(value) > index)
        for index in range(device_count)
    ]
    return {
        "sampling_interval_target_seconds": 1,
        "sampling_overhead_total_ms": sum(
            sample["sampling_overhead_ms"] for sample in samples if isinstance(sample.get("sampling_overhead_ms"), int)
        ),
        "agent_process_tree_rss_sampled_max_bytes": sampled_maximum("agent_process_tree_rss_bytes"),
        "agent_process_tree_cpu_time_sampled_max_ms": sampled_maximum("agent_process_tree_cpu_time_ms"),
        "gpu_device_memory_used_sampled_max_mib": gpu_maxima or None,
        "agent_memory_scope": "agent process tree RSS; shared pages may be counted more than once",
        "gpu_memory_scope": "device-wide; includes the model server and other GPU clients",
    }


def provider_reported_usage(agent: str, trace_path: Path, stdout_path: Path) -> dict[str, Any]:
    """Read token counters explicitly reported by the agent/provider adapters."""
    fields = {
        "input_tokens": None,
        "output_tokens": None,
        "reasoning_tokens": None,
        "cache_read_tokens": None,
        "cache_write_tokens": None,
    }
    if agent == "veasel":
        source = "veasel_atif_final_metrics"
        try:
            trajectory = json.loads(trace_path.read_text())
        except (OSError, json.JSONDecodeError):
            return {"reported": False, "source": source, "trace_step_count": None,
                    "reported_agent_cost_usd": None, **fields}
        if not isinstance(trajectory, dict):
            return {"reported": False, "source": source, "trace_step_count": None,
                    "reported_agent_cost_usd": None, **fields}
        extra = trajectory.get("extra", {})
        extra = extra if isinstance(extra, dict) else {}
        steps = trajectory.get("steps", [])
        step_count = len(steps) if isinstance(steps, list) else None
        if extra.get("token_usage") != "reported":
            return {"reported": False, "source": source, "trace_step_count": step_count,
                    "reported_agent_cost_usd": None, **fields}
        metrics = trajectory.get("final_metrics", {})
        metrics = metrics if isinstance(metrics, dict) else {}
        values = {
            "input_tokens": metrics.get("total_prompt_tokens"),
            "output_tokens": metrics.get("total_completion_tokens"),
            "reasoning_tokens": metrics.get("reasoning_tokens"),
            "cache_read_tokens": metrics.get("cache_read_tokens"),
            "cache_write_tokens": metrics.get("cache_creation_tokens"),
        }
        for key, value in values.items():
            if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
                fields[key] = value
        return {
            "reported": fields["input_tokens"] is not None or fields["output_tokens"] is not None,
            "source": source,
            "trace_step_count": step_count,
            "reported_agent_cost_usd": None,
            "cost_note": "Veasel ATIF does not export a cost value",
            **fields,
        }

    source = "opencode_json_step_finish_events"
    step_count = 0
    reported_keys: set[str] = set()
    reported_agent_cost_usd: float | None = None
    try:
        with stdout_path.open(errors="replace") as stdout:
            for line in stdout:
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(event, dict) or event.get("type") not in {"step_finish", "step-finish"}:
                    continue
                part = event.get("part")
                part = part if isinstance(part, dict) else {}
                tokens = part.get("tokens", event.get("tokens"))
                step_count += 1
                tokens = tokens if isinstance(tokens, dict) else {}
                token_values = {
                    "input_tokens": tokens.get("input"),
                    "output_tokens": tokens.get("output"),
                    "reasoning_tokens": tokens.get("reasoning"),
                }
                cache = tokens.get("cache")
                cache = cache if isinstance(cache, dict) else {}
                token_values["cache_read_tokens"] = cache.get("read")
                token_values["cache_write_tokens"] = cache.get("write")
                for key, value in token_values.items():
                    if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
                        fields[key] = (fields[key] or 0) + value
                        reported_keys.add(key)
                cost = part.get("cost", event.get("cost"))
                if isinstance(cost, (int, float)) and not isinstance(cost, bool) and cost >= 0:
                    reported_agent_cost_usd = (reported_agent_cost_usd or 0.0) + cost
    except OSError:
        pass
    return {
        "reported": bool(reported_keys),
        "source": source,
        "usage_event_count": step_count,
        "reported_agent_cost_usd": reported_agent_cost_usd,
        "cost_note": "OpenCode-reported cost; local-model zero may mean no configured price",
        **fields,
    }


def estimate_provider_cost(case: dict[str, Any], usage: dict[str, Any]) -> str | None:
    """Estimate configured-provider cost from reported usage and pinned rates."""
    budget = case.get("cost_budget")
    input_tokens = usage.get("input_tokens")
    output_tokens = usage.get("output_tokens")
    if not isinstance(budget, dict) or not isinstance(input_tokens, int) or not isinstance(output_tokens, int):
        return None
    try:
        input_rate = Decimal(str(budget["input_usd_per_million_tokens"]))
        output_rate = Decimal(str(budget["output_usd_per_million_tokens"]))
        cached_tokens = usage.get("cache_read_tokens")
        cached_tokens = cached_tokens if isinstance(cached_tokens, int) and not isinstance(cached_tokens, bool) else 0
        cached_tokens = min(max(cached_tokens, 0), input_tokens)
        cached_rate = Decimal(str(budget.get("cached_input_usd_per_million_tokens", budget["input_usd_per_million_tokens"])))
        cost = (Decimal(input_tokens - cached_tokens) * input_rate
                + Decimal(cached_tokens) * cached_rate
                + Decimal(output_tokens) * output_rate) / Decimal(1_000_000)
        return str(cost.quantize(Decimal("0.00000001"))) if cost.is_finite() and cost >= 0 else None
    except (KeyError, InvalidOperation, TypeError, ValueError):
        return None


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


def ollama_gpu_placement(base_url: str, model: str) -> dict[str, Any]:
    request = urllib.request.Request(base_url.rstrip("/") + "/api/ps")
    with urllib.request.urlopen(request, timeout=3) as response:
        models = json.load(response).get("models", [])
    matches = [item for item in models if item.get("name") == model]
    if len(matches) != 1:
        raise RuntimeError(f"Ollama did not report exactly one loaded {model!r} model")
    item = matches[0]
    return {
        "name": str(item.get("name", "")),
        "digest": str(item.get("digest", "")),
        "size_bytes": int(item.get("size", 0)),
        "size_vram_bytes": int(item.get("size_vram", 0)),
        "context_length": int(item.get("context_length", 0)),
        "runner": str(item.get("runner", "")),
    }


def gpu_info() -> dict[str, Any]:
    output = subprocess.check_output(
        ["nvidia-smi", "--query-gpu=name,memory.total", "--format=csv,noheader,nounits"],
        text=True,
    ).splitlines()[0]
    name, memory_mib = output.rsplit(",", 1)
    return {"name": name.strip(), "memory_mib": int(memory_mib.strip())}


def configured_model(data_dir: Path) -> dict[str, Any]:
    settings = json.loads((data_dir / "model-settings.json").read_text())
    if not isinstance(settings, dict):
        raise ValueError("model settings must be an object")
    provider = settings.get("active_provider", "")
    provider = provider if isinstance(provider, str) else ""
    profiles = settings.get("profiles", {})
    profiles = profiles if isinstance(profiles, dict) else {}
    profile = profiles.get(provider, {})
    if not isinstance(profile, dict):
        profile = {}
    max_output_tokens = profile.get("max_output_tokens", 0)
    return {
        "provider": provider,
        "model": profile.get("model", ""),
        "base_url": profile.get("base_url", ""),
        "max_output_tokens": max_output_tokens if isinstance(max_output_tokens, int) and not isinstance(max_output_tokens, bool) else 0,
        "api_key_saved": isinstance(profile.get("api_key"), str) and bool(profile["api_key"].strip()),
    }


def private_profile_key(data_dir: Path) -> str:
    settings_path = data_dir / "model-settings.json"
    settings = json.loads(settings_path.read_text())
    provider = settings.get("active_provider", "")
    profile = settings.get("profiles", {}).get(provider, {})
    key = profile.get("api_key", "") if isinstance(profile, dict) else ""
    if not isinstance(key, str) or not key.strip():
        raise ValueError("saved provider credential disappeared after preflight")
    return key


def remove_profile_key_from_disk(data_dir: Path) -> None:
    """Move the key to the backend-only environment, then scrub benchmark state."""
    settings_path = data_dir / "model-settings.json"
    settings = json.loads(settings_path.read_text())
    provider = settings.get("active_provider", "")
    profiles = settings.get("profiles", {})
    profile = profiles.get(provider, {}) if isinstance(profiles, dict) else {}
    if not isinstance(profile, dict):
        raise ValueError("saved provider profile is invalid")
    profile.pop("api_key", None)
    temporary = settings_path.with_name(f".{settings_path.name}.scrubbed")
    temporary.write_text(json.dumps(settings))
    temporary.chmod(0o600)
    os.replace(temporary, settings_path)


def safe_provider_config_report(case: dict[str, Any]) -> dict[str, Any]:
    """Allowlist non-secret provider identity/settings, excluding endpoint URLs."""
    config = case.get("provider_config", {})
    if not isinstance(config, dict):
        return {}
    safe: dict[str, Any] = {}
    mode = config.get("mode")
    if mode == "veasel-profile":
        safe["mode"] = mode
    credential = config.get("credential")
    if isinstance(credential, str) and credential in {"saved-profile", "none"}:
        safe["credential"] = credential
    provider = config.get("provider")
    if isinstance(provider, str) and 0 < len(provider) <= 128 and provider.isascii() \
        and all(char.isalnum() or char in "._+-" for char in provider):
        safe["provider"] = provider
    model = config.get("model")
    if isinstance(model, str) and 0 < len(model) <= 200 and model.isascii() and "://" not in model \
        and all(char.isalnum() or char in "._:/+-" for char in model):
        safe["model"] = model
    output_tokens = config.get("max_output_tokens")
    if isinstance(output_tokens, int) and not isinstance(output_tokens, bool) and output_tokens > 0:
        safe["max_output_tokens"] = output_tokens
    api_key_saved = config.get("api_key_saved")
    if isinstance(api_key_saved, bool):
        safe["api_key_saved"] = api_key_saved
    return safe


def provider_cost_bound(case: dict[str, Any], approved_spend_usd: str) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Compute a conservative configured-provider upper bound before any model call."""
    checks: list[dict[str, Any]] = []
    budget = case.get("cost_budget", {})

    def check(name: str, ok: bool, actual: Any, required: Any) -> None:
        checks.append({"name": name, "passed": ok, "actual": actual, "required": required})

    try:
        approved = Decimal(approved_spend_usd)
        ceiling = Decimal(str(budget["max_cost_usd"]))
        input_rate = Decimal(str(budget["input_usd_per_million_tokens"]))
        output_rate = Decimal(str(budget["output_usd_per_million_tokens"]))
        request_cap = budget["max_model_requests"]
        context_tokens = case["model"]["context_tokens"]
        output_tokens = case["model"]["output_tokens"]
        numeric_values = (approved, ceiling, input_rate, output_rate)
        valid_numbers = all(value.is_finite() and value >= 0 for value in numeric_values)
        valid_counts = all(isinstance(value, int) and not isinstance(value, bool) and value > 0
                           for value in (request_cap, context_tokens, output_tokens))
        request_cap_matches_runtime = request_cap == (
            PINNED_VEASEL_MAX_MODEL_ROUNDS * PINNED_PROVIDER_HTTP_ATTEMPTS_PER_ROUND
        )
        bound = (Decimal(request_cap) * (Decimal(context_tokens) * input_rate
                                         + Decimal(output_tokens) * output_rate) / Decimal(1_000_000)
                 if valid_numbers and valid_counts else None)
        safe = valid_numbers and valid_counts and request_cap_matches_runtime and ceiling > 0 and approved > 0 \
            and ceiling <= approved and bound is not None and bound <= ceiling
        report = {
            "approved_spend_usd": str(approved) if approved.is_finite() else "invalid",
            "max_cost_usd": str(ceiling) if ceiling.is_finite() else "invalid",
            "max_model_requests": request_cap if valid_counts else None,
            "pinned_runtime_max_model_requests": PINNED_VEASEL_MAX_MODEL_ROUNDS * PINNED_PROVIDER_HTTP_ATTEMPTS_PER_ROUND,
            "input_usd_per_million_tokens": str(input_rate) if input_rate.is_finite() else "invalid",
            "output_usd_per_million_tokens": str(output_rate) if output_rate.is_finite() else "invalid",
            "worst_case_input_tokens": request_cap * context_tokens if valid_counts else None,
            "worst_case_output_tokens": request_cap * output_tokens if valid_counts else None,
            "conservative_max_cost_usd": str(bound.quantize(Decimal("0.00000001"))) if bound is not None else None,
            "cost_basis": "all input billed at uncached rate; every request uses full context and output caps",
        }
        check("approved_cost_ceiling", safe, report,
              "model request cap matches pinned runtime (28 rounds including the tool-budget summary x 3 HTTP attempts); positive operator authorization; ceiling <= authorization; worst-case token cost <= ceiling")
        return report, checks
    except (KeyError, InvalidOperation, TypeError, ValueError):
        report = {"cost_basis": "missing or invalid configured-provider cost budget"}
        check("approved_cost_ceiling", False, report, "valid rates, request cap, model limits, and approved spend")
        return report, checks


def safe_endpoint(value: Any) -> bool:
    """Accept HTTP(S) endpoints without URL-carried credentials or query secrets."""
    if not isinstance(value, str) or not value or any(ord(char) < 0x20 for char in value):
        return False
    try:
        parsed = urlsplit(value)
        return parsed.scheme in {"http", "https"} and bool(parsed.hostname) \
            and parsed.username is None and parsed.password is None \
            and not parsed.query and not parsed.fragment
    except ValueError:
        return False


def repository_identity(value: Any) -> tuple[str, str, int | None, str] | None:
    """Parse repository identity without retaining URL credentials or query data."""
    if not isinstance(value, str) or any(ord(char) < 0x20 for char in value):
        return None
    try:
        parsed = urlsplit(value)
        hostname = parsed.hostname
        port = parsed.port
    except ValueError:
        return None
    if parsed.scheme not in {"http", "https"} or not hostname or parsed.query or parsed.fragment:
        return None
    path = parsed.path.rstrip("/").removesuffix(".git")
    return parsed.scheme.lower(), hostname.lower(), port, path


def configured_provider_target(case: dict[str, Any], data_dir: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Check a non-Ollama target against Veasel's saved profile without probing it."""
    expected = case["provider_config"]
    model = case["model"]
    checks: list[dict[str, Any]] = []

    def check(name: str, ok: bool, actual: Any, required: Any) -> None:
        checks.append({"name": name, "passed": ok, "actual": actual, "required": required})

    try:
        actual = configured_model(data_dir)
    except (OSError, KeyError, ValueError, json.JSONDecodeError):
        actual = {"provider": "", "model": "", "base_url": "", "max_output_tokens": 0,
                  "api_key_saved": False}
    provider = model.get("provider", "")
    model_name = model.get("name", "")
    expected_endpoint = expected.get("base_url", "")
    check("provider_model_selection", actual["provider"] == provider and actual["model"] == model_name,
          {"provider": actual["provider"], "model": actual["model"]},
          {"provider": provider, "model": model_name})
    endpoint_matches = safe_endpoint(expected_endpoint) and safe_endpoint(actual["base_url"]) \
        and actual["base_url"] == expected_endpoint
    check("provider_endpoint", endpoint_matches,
          "matched" if endpoint_matches else "missing, unsafe, or mismatched",
          "safe configured case endpoint")
    output_tokens = model.get("output_tokens", 0)
    context_tokens = model.get("context_tokens", 0)
    check("provider_context_budget", isinstance(context_tokens, int) and not isinstance(context_tokens, bool)
          and context_tokens > 0,
          context_tokens, "positive integer")
    check("provider_output_budget", isinstance(output_tokens, int) and not isinstance(output_tokens, bool)
          and output_tokens > 0 and actual["max_output_tokens"] >= output_tokens,
          actual["max_output_tokens"], {"at_least": output_tokens})
    credential_policy = expected.get("credential", "")
    requires_key = credential_policy == "saved-profile"
    check("provider_credential_policy", credential_policy in {"saved-profile", "none"},
          credential_policy or "missing", ["saved-profile", "none"])
    check("provider_credential_ready", not requires_key or actual["api_key_saved"],
          "saved" if actual["api_key_saved"] else "missing",
          "saved profile credential" if requires_key else "no credential required")
    return actual, checks


def open_code_version(binary: str) -> str:
    return subprocess.check_output([binary, "--version"], text=True, stderr=subprocess.DEVNULL).strip()


def veasel_version(binary: str) -> str:
    return subprocess.check_output([binary, "--version"], text=True, stderr=subprocess.DEVNULL).strip()


def binary_sha256(binary: str) -> str | None:
    try:
        return hashlib.sha256(Path(binary).read_bytes()).hexdigest()
    except OSError:
        return None


def open_code_config(case: dict[str, Any]) -> dict[str, Any]:
    model_name = case["model"]["name"]
    model_id = case["comparators"]["opencode_model"]
    permissions = [{"action": "*", "resource": "*", "effect": "deny"}]
    permissions.extend(
        {"action": action, "resource": "*", "effect": "allow"}
        for action in case["permissions"]["tool_allowlist"]
    )
    permissions.append({"action": "external_directory", "resource": "*", "effect": "deny"})
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
        "agents": {"build": {"permissions": permissions}},
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
               "--agent", case["comparators"]["opencode_agent"], "--format", "json", prompt]
    if case["comparators"]["opencode_auto_approve"]:
        command.insert(3, "--auto")
    return command


def validated_isolation_wrapper(args: argparse.Namespace) -> tuple[Path, str]:
    """Require the operator's pinned launcher that enforces task isolation."""
    wrapper_arg = getattr(args, "isolation_wrapper", None)
    expected_hash = getattr(args, "isolation_wrapper_sha256", None)
    if not wrapper_arg or not expected_hash:
        raise ValueError("an operator-managed isolation wrapper and its SHA-256 are required")
    if len(expected_hash) != 64 or any(char not in "0123456789abcdefABCDEF" for char in expected_hash):
        raise ValueError("isolation wrapper SHA-256 must be 64 hexadecimal characters")
    wrapper_input = Path(wrapper_arg).expanduser()
    if not wrapper_input.is_absolute():
        raise ValueError("isolation wrapper path must be absolute")
    wrapper = wrapper_input.resolve(strict=True)
    if not wrapper.is_file() or not os.access(wrapper, os.X_OK):
        raise ValueError("isolation wrapper must be an executable regular file")
    actual_hash = hashlib.sha256(wrapper.read_bytes()).hexdigest()
    if actual_hash.lower() != expected_hash.lower():
        raise ValueError("isolation wrapper SHA-256 does not match the reviewed operator pin")
    return wrapper, actual_hash


def wrapped_command(wrapper: Path, command: list[str]) -> list[str]:
    """Pass the agent command to the pinned wrapper using its `--` contract."""
    return [str(wrapper), "--", *command]


def git(workspace: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(workspace), *args], text=True).strip()


def preflight(case_path: Path, workspace: Path, ollama_url: str, data_dir: Path, agent: str = "veasel", agent_binary: str = "opencode", approved_spend_usd: str = "0") -> dict[str, Any]:
    case, _prompt_path, prompt_hash = load_case(case_path)
    model = case["model"]
    is_ollama = model.get("provider") == "ollama"
    available, swap = available_resources()
    checks: list[dict[str, Any]] = []

    def check(name: str, ok: bool, actual: Any, required: Any) -> None:
        checks.append({"name": name, "passed": ok, "actual": actual, "required": required})

    check("prompt_sha256", prompt_hash == case["prompt_sha256"], prompt_hash, case["prompt_sha256"])
    origin = git(workspace, "remote", "get-url", "origin")
    repository_matches = repository_identity(origin) is not None \
        and repository_identity(origin) == repository_identity(case["repository"])
    check("repository", repository_matches,
          "matched" if repository_matches else "mismatch or invalid pinned repository identity",
          "pinned repository identity")
    revision = git(workspace, "rev-parse", "HEAD")
    check("base_commit", revision == case["base_commit"], revision, case["base_commit"])
    dirty = git(workspace, "status", "--porcelain")
    check("clean_workspace", not dirty, not bool(dirty), True)
    ollama_target_safe = False
    if is_ollama:
        expected_ollama_url = case["provider_config"]["base_url"].rstrip("/").removesuffix("/v1")
        actual_ollama_url = ollama_url.rstrip("/")
        endpoint_matches = safe_endpoint(expected_ollama_url) and safe_endpoint(actual_ollama_url) \
            and actual_ollama_url == expected_ollama_url
        ollama_target_safe = endpoint_matches
        check("ollama_endpoint", endpoint_matches,
              "matched" if endpoint_matches else "missing, unsafe, or mismatched",
              "safe pinned Ollama endpoint")
    if agent == "veasel" and is_ollama:
        expected_config = case["provider_config"]
        try:
            actual_config = configured_model(data_dir)
            config_matches = all(actual_config.get(key) == value for key, value in expected_config.items())
            safe_actual = {key: actual_config[key] for key in ("provider", "model", "max_output_tokens", "api_key_saved")}
            safe_expected = safe_provider_config_report(case)
            check("veasel_model_config", config_matches, safe_actual, safe_expected)
        except (OSError, KeyError, json.JSONDecodeError) as exc:
            check("veasel_model_config", False, type(exc).__name__, safe_provider_config_report(case))
    elif agent == "opencode" and is_ollama:
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
    elif not is_ollama:
        cost_report, cost_checks = provider_cost_bound(case, approved_spend_usd)
        checks.extend(cost_checks)
        provider_config = case.get("provider_config", {})
        check("case_provider_consistency",
              provider_config.get("provider") == model.get("provider")
              and provider_config.get("model") == model.get("name")
              and provider_config.get("mode") == "veasel-profile",
              {"provider": provider_config.get("provider"), "model": provider_config.get("model")},
              {"mode": "veasel-profile", "provider": model.get("provider"), "model": model.get("name")})
        if agent == "veasel":
            _actual, provider_checks = configured_provider_target(case, data_dir)
            checks.extend(provider_checks)
            expected_version = case.get("runtime", {}).get("veasel_version")
            if expected_version:
                binary = shutil.which(agent_binary)
                if not binary:
                    check("veasel_version", False, "not_installed", expected_version)
                else:
                    try:
                        actual_version = veasel_version(binary)
                        check("veasel_version", actual_version == expected_version,
                              actual_version, expected_version)
                        expected_hash = case.get("runtime", {}).get("veasel_binary_sha256")
                        if expected_hash:
                            actual_hash = hashlib.sha256(Path(binary).read_bytes()).hexdigest()
                            check("veasel_binary_sha256", actual_hash == expected_hash,
                                  actual_hash, expected_hash)
                    except (OSError, subprocess.CalledProcessError) as exc:
                        check("veasel_version", False, type(exc).__name__, expected_version)
            # This records the limit explicitly: config readiness is not a
            # network probe or proof that the provider hosts the model.
            check("provider_live_readiness", True, "not_probed", "live provider/model availability is unverified")
        else:
            check("opencode_non_ollama_target", False, "unsupported", "Veasel configured-profile adapter")
    if is_ollama:
        expected = model["digest"]
        if ollama_target_safe:
            try:
                actual_digest = model_digest(ollama_url, model["name"])
                check("model_digest", actual_digest == expected, actual_digest, expected)
            except (OSError, RuntimeError, urllib.error.URLError, json.JSONDecodeError) as exc:
                check("model_digest", False, type(exc).__name__, expected)
        else:
            check("model_digest", False, "not_probed_unsafe_or_mismatched_endpoint", "pinned model digest")
    expected_ollama = case.get("runtime", {}).get("ollama_version")
    if expected_ollama and ollama_target_safe:
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
    if is_ollama and case.get("runtime", {}).get("accelerator") == "CUDA":
        if not ollama_target_safe:
            check("ollama_model_gpu_placement", False,
                  "not_probed_unsafe_or_mismatched_endpoint", "pinned model placement at pinned context")
        else:
            try:
                placement = ollama_gpu_placement(ollama_url, model["name"])
                expected_context = model["context_tokens"]
                gpu_loaded = placement["size_vram_bytes"] >= placement["size_bytes"] > 0
                context_matches = placement["context_length"] >= expected_context
                expected_placement = {
                    "name": model["name"],
                    "digest": model["digest"],
                    "size_vram_bytes_at_least": placement["size_bytes"],
                    "context_length_at_least": expected_context,
                }
                check(
                    "ollama_model_gpu_placement",
                    placement["name"] == model["name"]
                    and placement["digest"] == model["digest"]
                    and gpu_loaded
                    and context_matches,
                    placement,
                    expected_placement,
                )
            except (OSError, RuntimeError, urllib.error.URLError, json.JSONDecodeError, TypeError, ValueError) as exc:
                check("ollama_model_gpu_placement", False, type(exc).__name__, "model loaded on CUDA at pinned context")
    min_memory = case["budgets"]["minimum_available_memory_bytes"]
    min_startup_memory = case["budgets"].get("minimum_startup_available_memory_bytes", min_memory)
    min_swap = case["budgets"]["minimum_free_swap_bytes"]
    check("available_memory", available >= min_memory, available, min_memory)
    check("startup_memory_headroom", available >= min_startup_memory, available, min_startup_memory)
    check("free_swap", swap >= min_swap, swap, min_swap)
    return {
        "schema": "veasel.real-task-preflight.v1",
        "case_id": case["id"],
        "case_sha256": hashlib.sha256(case_path.read_bytes()).hexdigest(),
        "agent": agent,
        "passed": all(item["passed"] for item in checks),
        "checks": checks,
        "resources_bytes": {"available_memory": available, "free_swap": swap},
        "cost_budget": cost_report if not is_ollama else None,
    }


def run_case(args: argparse.Namespace) -> int:
    try:
        isolation_wrapper, isolation_wrapper_sha256 = validated_isolation_wrapper(args)
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"Refusing autonomous run: {exc}", file=sys.stderr)
        return 2
    case, _prompt_path, _prompt_hash = load_case(args.case)
    workspace = args.workspace.resolve()
    data_dir = args.data_dir.resolve()
    agent_binary_arg = args.veasel if args.agent == "veasel" else args.opencode
    result = preflight(args.case, workspace, args.ollama_url, data_dir, args.agent,
                       agent_binary_arg, args.approved_spend_usd)
    if not result["passed"]:
        print(json.dumps(result, indent=2))
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
        if case.get("provider_config", {}).get("credential") == "saved-profile":
            env["VEASEL_MODEL_API_KEY"] = private_profile_key(data_dir)
            remove_profile_key_from_disk(data_dir)
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
    command = wrapped_command(isolation_wrapper, command)
    started = time.monotonic()
    min_memory = case["budgets"]["minimum_available_memory_bytes"]
    min_swap = case["budgets"]["minimum_free_swap_bytes"]
    samples: list[dict[str, Any]] = []
    outcome = "completed"
    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        stdout_path.chmod(0o600)
        stderr_path.chmod(0o600)
        process = subprocess.Popen(command, cwd=workspace, env=env, stdout=stdout, stderr=stderr, start_new_session=True)
        while process.poll() is None:
            sampled_at = time.monotonic()
            available, swap = available_resources()
            sample: dict[str, Any] = {
                "elapsed_ms": int((sampled_at - started) * 1000),
                "available_memory": available,
                "free_swap": swap,
            }
            process_resources = process_tree_resources(process.pid)
            if process_resources is not None:
                sample["agent_process_count"] = process_resources["process_count"]
                sample["agent_process_tree_cpu_time_ms"] = process_resources["cpu_time_ms"]
                sample["agent_process_tree_rss_bytes"] = process_resources["rss_bytes"]
            sample["gpu_memory_used_mib"] = gpu_memory_used_mib()
            sample["sampling_overhead_ms"] = int((time.monotonic() - sampled_at) * 1000)
            samples.append(sample)
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
            sample_delay = 1 - (time.monotonic() - sampled_at)
            if sample_delay > 0:
                time.sleep(sample_delay)
        return_code = process.wait()
    if outcome == "completed" and return_code != 0:
        outcome = "agent_error"
    usage = provider_reported_usage(args.agent, trace_path, stdout_path)
    report = {
        "schema": "veasel.real-task-attempt.v1",
        "case_id": case["id"],
        "case_sha256": hashlib.sha256(args.case.read_bytes()).hexdigest(),
        "base_commit": case["base_commit"],
        "prompt_sha256": case["prompt_sha256"],
        "model": case["model"],
        "provider_provenance": {
            "provider": case["model"]["provider"],
            "model": case["model"]["name"],
            "selection_source": "versioned_case_and_configured_profile" if case["model"]["provider"] != "ollama" else "versioned_case",
            "remote_model_readiness": "not_probed" if case["model"]["provider"] != "ollama" else "ollama_digest_verified",
        },
        "provider_config": safe_provider_config_report(case),
        "budgets": case["budgets"],
        "runtime": case["runtime"],
        "permissions": case["permissions"],
        "isolation": {
            "mode": "operator_managed_wrapper",
            "wrapper_sha256": isolation_wrapper_sha256,
            "contract": "operator-reviewed wrapper enforces disposable workspace and task isolation",
        },
        "host": {"platform": platform.platform(), "machine": platform.machine(), "processor": platform.processor()},
        "agent": args.agent,
        "agent_version": open_code_version(agent_binary) if args.agent == "opencode" else subprocess.check_output([agent_binary, "--version"], text=True).strip(),
        "agent_binary_sha256": binary_sha256(agent_binary),
        "preflight": result,
        "outcome": outcome,
        "return_code": return_code,
        "wall_ms": int((time.monotonic() - started) * 1000),
        "resource_samples": samples,
        "resource_measurements": resource_measurement_summary(samples),
        "provider_usage": usage,
        "estimated_provider_cost_usd": estimate_provider_cost(case, usage),
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
        sub.add_argument("--approved-spend-usd", default="0",
                         help="operator-authorized maximum spend for configured remote-provider cases")
        if action == "run":
            sub.add_argument("--artifacts", type=Path, required=True)
            sub.add_argument("--isolation-wrapper", type=Path, required=True,
                             help="absolute path to an operator-reviewed wrapper that enforces task isolation")
            sub.add_argument("--isolation-wrapper-sha256", required=True,
                             help="SHA-256 pin for the reviewed isolation wrapper")
    args = parser.parse_args()
    try:
        if args.action == "preflight":
            agent_binary = args.veasel if args.agent == "veasel" else args.opencode
            report = preflight(args.case, args.workspace.resolve(), args.ollama_url, args.data_dir.resolve(), args.agent, agent_binary, args.approved_spend_usd)
            print(json.dumps(report, indent=2))
            return 0 if report["passed"] else 2
        return run_case(args)
    except (OSError, subprocess.CalledProcessError, KeyError, json.JSONDecodeError) as exc:
        print(f"preflight error: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
