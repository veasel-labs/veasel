#!/usr/bin/env python3
"""Preflight and run a versioned, local-model coding task case."""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import platform
import secrets
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

try:
    import fcntl as _fcntl
except ImportError:  # Remote benchmark isolation is Linux-only; local cases remain portable.
    _fcntl = None
fcntl: Any = _fcntl

from responses_proxy import BudgetProxy


ROOT = Path(__file__).resolve().parent
GIB = 1024**3
PINNED_PROVIDER_HTTP_ATTEMPTS_PER_ROUND = 3
PINNED_VEASEL_RUNTIME_MODEL_ROUNDS = {
    ("Veasel Code 0.79.5-next.0", "93f0726e998ee7234e0d2cc7d7019471e5c1c1202b35992a703bd7afd3233a7e"): 28,
    ("Veasel Code 0.79.8-next.0", "78164aaf24db5f33c9059db5398aa9af6efe13831bca55c6c92f067f4245fffe"): 28,
    ("Veasel Code 0.79.11-next.0", "b2d03e4d04d72e3af22d3aab78dbd51e623ccd72df4c004edaf7c92f22af6ac6"): 42,
}
AUTHORIZED_AGGREGATE_SPEND_USD = Decimal("5.00")
IMPORTED_PRIOR_SPEND_USD = Decimal("0.35444")
IMPORTED_PRIOR_SPEND_NOTE = (
    "Approximate USD 0.35444 aggregate spend imported from the previous-session handoff; "
    "raw source was not available for independent verification. Treated as consumed and never refunded."
)
OPEN_CODE_SHELL_WRAPPER = ROOT / "opencode-shell-sandbox.sh"
OPEN_CODE_SHELL_WRAPPER_SHA256 = "71c2acbfd29a9ebad5634060418b9dfed4ea8626fbdb0ba0c32e8bc5258e7388"
REMOTE_CASE_PINS = {
    "veasel-labs/website#173-muse-spark-1.3-contributor-veasel-0.79.5": {
        "case_sha256": "5db9f79592bad398135f5f724938dc57b6e096c1c12e8470deaf56b0ed06c9af",
        "max_cost_usd": Decimal("0.11"),
        "max_model_requests": 84,
        "max_request_body_bytes": 32768,
    },
    "veasel-labs/website#173-muse-spark-1.3-contributor-veasel-0.79.8": {
        "case_sha256": "eec274a8a5cc71f6e03c50c2f449b59baaa0abe97cdd9c5f08d3f74bdb3e09c7",
        "max_cost_usd": Decimal("0.11"),
        "max_model_requests": 84,
        "max_request_body_bytes": 32768,
    },
    "veasel-labs/website#173-muse-spark-1.3-contributor-veasel-0.79.11": {
        "case_sha256": "22bd53fc52f182f79ef51eebb78d8249e443fed61d6ca29833f6a173c7422358",
        "max_cost_usd": Decimal("0.16"),
        "max_model_requests": 126,
        "max_request_body_bytes": 32768,
    },
}
REMOTE_CASE_MODEL = "muse-spark-1.3-contributor"
REMOTE_CASE_PROVIDER = "meta"
REMOTE_CASE_BASE_URL = "https://api.meta.ai/v1"
REMOTE_CASE_CONTEXT_TOKENS = 8192
REMOTE_CASE_OUTPUT_TOKENS = 2048
REMOTE_CASE_INPUT_USD_PER_MILLION = Decimal("0.1")
REMOTE_CASE_OUTPUT_USD_PER_MILLION = Decimal("0.2")


def validate_remote_case_pin(case_path: Path, case: dict[str, Any]) -> str | None:
    """Allow only the reviewed remote case and its fixed rate/budget contract."""
    if case.get("model", {}).get("provider") == "ollama":
        return None
    raw = case_path.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    try:
        disk_case = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError("remote benchmark case is not valid pinned JSON") from exc
    remote_pin = REMOTE_CASE_PINS.get(disk_case.get("id"))
    approved_digest = remote_pin.get("case_sha256") if remote_pin else None
    expected = {
        "model": {
            "provider": REMOTE_CASE_PROVIDER,
            "name": REMOTE_CASE_MODEL,
            "context_tokens": REMOTE_CASE_CONTEXT_TOKENS,
            "output_tokens": REMOTE_CASE_OUTPUT_TOKENS,
        },
        "provider_config": {
            "provider": REMOTE_CASE_PROVIDER,
            "model": REMOTE_CASE_MODEL,
            "base_url": REMOTE_CASE_BASE_URL,
        },
        "cost_budget": {
            "max_cost_usd": float(remote_pin["max_cost_usd"]) if remote_pin else None,
            "input_usd_per_million_tokens": float(REMOTE_CASE_INPUT_USD_PER_MILLION),
            "output_usd_per_million_tokens": float(REMOTE_CASE_OUTPUT_USD_PER_MILLION),
            "max_model_requests": remote_pin["max_model_requests"] if remote_pin else None,
            "max_request_body_bytes": remote_pin["max_request_body_bytes"] if remote_pin else None,
        },
    }
    if approved_digest != digest or disk_case != case:
        raise ValueError("remote benchmark case hash is not in the reviewed allowlist")
    for key, value in expected.items():
        actual = disk_case.get(key)
        if key == "provider_config":
            actual = {field: actual.get(field) for field in value} if isinstance(actual, dict) else actual
        if key == "cost_budget":
            actual = {field: actual.get(field) for field in value} if isinstance(actual, dict) else actual
        if actual != value:
            raise ValueError("remote benchmark model, provider rates, or limits differ from reviewed pins")
    return digest


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


def terminate_process_group(process: subprocess.Popen[Any], grace_seconds: float = 3.0) -> bool:
    """Stop and reap an agent session and its same-process-group descendants."""
    process_group = process.pid

    def signal_group(signal_number: int) -> bool:
        try:
            os.killpg(process_group, signal_number)
            return True
        except ProcessLookupError:
            return True
        except OSError:
            return False

    def group_exists() -> bool:
        try:
            os.killpg(process_group, 0)
            return True
        except ProcessLookupError:
            return False
        except OSError:
            return True

    if not signal_group(signal.SIGINT):
        return False
    try:
        process.wait(timeout=grace_seconds)
    except subprocess.TimeoutExpired:
        if not signal_group(signal.SIGTERM):
            return False
        try:
            process.wait(timeout=1.0)
        except subprocess.TimeoutExpired:
            if not signal_group(signal.SIGKILL):
                return False
            try:
                process.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                return False

    deadline = time.monotonic() + 1.0
    while group_exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    if not group_exists():
        return True
    if not signal_group(signal.SIGKILL):
        return False
    deadline = time.monotonic() + 1.0
    while group_exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    return not group_exists()


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
            return veasel_cli_usage_summary(stdout_path)
        if not isinstance(trajectory, dict):
            return veasel_cli_usage_summary(stdout_path)
        extra = trajectory.get("extra", {})
        extra = extra if isinstance(extra, dict) else {}
        steps = trajectory.get("steps", [])
        step_count = len(steps) if isinstance(steps, list) else None
        if extra.get("token_usage") != "reported":
            return veasel_cli_usage_summary(stdout_path, step_count)
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


def veasel_cli_usage_summary(stdout_path: Path, trace_step_count: int | None = None) -> dict[str, Any]:
    """Use Veasel's final JSON usage summary when the ATIF trajectory was not persisted."""
    fields = {
        "input_tokens": None,
        "output_tokens": None,
        "reasoning_tokens": None,
        "cache_read_tokens": None,
        "cache_write_tokens": None,
    }
    summary: dict[str, Any] | None = None
    try:
        with stdout_path.open(errors="replace") as stdout:
            for line in stdout:
                try:
                    value = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(value, dict) and value.get("session_usage_reported") is True:
                    summary = value
    except OSError:
        pass

    if summary is None:
        return {
            "reported": False,
            "source": "veasel_cli_session_summary",
            "trace_step_count": trace_step_count,
            "reported_turn_count": None,
            "reported_agent_cost_usd": None,
            "cost_note": "Veasel CLI reported no session usage summary",
            **fields,
        }

    keys = {
        "input_tokens": "session_input_tokens",
        "output_tokens": "session_output_tokens",
        "reasoning_tokens": "session_reasoning_tokens",
        "cache_read_tokens": "session_cache_read_tokens",
        "cache_write_tokens": "session_cache_write_tokens",
    }
    for field, key in keys.items():
        value = summary.get(key)
        if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
            fields[field] = value
    return {
        "reported": fields["input_tokens"] is not None or fields["output_tokens"] is not None,
        "source": "veasel_cli_session_summary",
        "trace_step_count": trace_step_count,
        "reported_turn_count": summary.get("session_reported_turns"),
        "reported_agent_cost_usd": None,
        "cost_note": "Veasel CLI session token counters; cost must be estimated from pinned rates",
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


def persistent_private_directory(path: Path) -> Path:
    """Create/check a private state directory that will survive system reboot."""
    resolved = path.resolve()
    for temporary_root in (Path("/tmp"), Path("/var/tmp")):
        if resolved == temporary_root or temporary_root in resolved.parents:
            raise ValueError("real-task state must be outside /tmp and /var/tmp")
    private_directory(resolved)
    info = resolved.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise ValueError("real-task state directory must be owned by the current user with mode 0700")
    return resolved


def install_opencode_shell_wrapper(data_dir: Path) -> tuple[Path, str]:
    source = OPEN_CODE_SHELL_WRAPPER
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    if digest != OPEN_CODE_SHELL_WRAPPER_SHA256:
        raise RuntimeError("repository OpenCode shell wrapper does not match the reviewed pin")
    private_directory(data_dir)
    destination = data_dir / "opencode-shell-sandbox.sh"
    if destination.exists() or destination.is_symlink():
        info = destination.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 \
                or hashlib.sha256(destination.read_bytes()).hexdigest() != digest:
            raise RuntimeError("private OpenCode shell wrapper differs from the reviewed pin")
    else:
        descriptor, temp_name = tempfile.mkstemp(prefix=".opencode-shell-sandbox-", dir=data_dir)
        try:
            os.fchmod(descriptor, 0o700)
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(source.read_bytes())
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temp_name, destination)
        except Exception:
            try:
                os.unlink(temp_name)
            except FileNotFoundError:
                pass
            raise
    return destination, digest


@contextlib.contextmanager
def spend_ledger(data_dir: Path):
    """Lock and load the durable aggregate budget ledger, importing prior spend once."""
    if fcntl is None:
        raise RuntimeError("aggregate spend ledger requires a platform with flock support")
    private_directory(data_dir)
    lock_path = data_dir / "aggregate-spend-ledger.lock"
    flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(lock_path, flags, 0o600)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise RuntimeError("aggregate spend ledger lock is not a private regular file")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        ledger_path = data_dir / "aggregate-spend-ledger.json"
        if ledger_path.exists():
            ledger_info = ledger_path.lstat()
            if not stat.S_ISREG(ledger_info.st_mode) or ledger_info.st_uid != os.getuid() \
                    or ledger_info.st_mode & 0o077:
                raise RuntimeError("aggregate spend ledger must be a private regular file")
            ledger = json.loads(ledger_path.read_text(), object_pairs_hook=_unique_json_object)
            _validate_spend_ledger(ledger)
        else:
            ledger = {
                "schema": "veasel.real-task-spend-ledger.v1",
                "authorized_total_usd": str(AUTHORIZED_AGGREGATE_SPEND_USD),
                "imported_prior_spend_usd": str(IMPORTED_PRIOR_SPEND_USD),
                "settled_spend_usd": str(IMPORTED_PRIOR_SPEND_USD),
                "prior_spend_provenance": IMPORTED_PRIOR_SPEND_NOTE,
                "reservations": {},
            }
            _validate_spend_ledger(ledger)
            _write_spend_ledger(ledger_path, ledger)
        if Decimal(ledger["authorized_total_usd"]) != AUTHORIZED_AGGREGATE_SPEND_USD:
            raise RuntimeError("aggregate spend authorization does not match the fixed USD 5.00 approval")
        yield ledger, lambda: _write_spend_ledger(ledger_path, ledger)
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


def _validate_spend_ledger(ledger: Any) -> None:
    if not isinstance(ledger, dict) or ledger.get("schema") != "veasel.real-task-spend-ledger.v1" \
            or not isinstance(ledger.get("reservations"), dict):
        raise RuntimeError("aggregate spend ledger has an unknown or malformed schema")
    for key in ("authorized_total_usd", "imported_prior_spend_usd", "settled_spend_usd"):
        try:
            value = Decimal(ledger[key])
        except (KeyError, InvalidOperation, TypeError) as exc:
            raise RuntimeError("aggregate spend ledger has invalid monetary values") from exc
        if not value.is_finite() or value < 0:
            raise RuntimeError("aggregate spend ledger has invalid monetary values")
    if ledger["imported_prior_spend_usd"] != str(IMPORTED_PRIOR_SPEND_USD) \
            or ledger.get("prior_spend_provenance") != IMPORTED_PRIOR_SPEND_NOTE:
        raise RuntimeError("aggregate spend ledger prior-spend provenance does not match the handoff")
    settled_reservations = Decimal(0)
    outstanding = Decimal(0)
    for run_id, reservation in ledger["reservations"].items():
        if not isinstance(run_id, str) or not isinstance(reservation, dict) \
                or reservation.get("status") not in {"reserved", "settled", "released"}:
            raise RuntimeError("aggregate spend ledger contains a malformed reservation")
        if reservation["status"] == "settled" and "actual_usd" not in reservation:
            raise RuntimeError("settled aggregate reservation is missing its actual usage")
        for key in ("reserved_usd", "actual_usd"):
            if key not in reservation:
                continue
            try:
                value = Decimal(reservation[key])
            except (InvalidOperation, TypeError) as exc:
                raise RuntimeError("aggregate spend ledger contains invalid reservation amounts") from exc
            if not value.is_finite() or value < 0:
                raise RuntimeError("aggregate spend ledger contains invalid reservation amounts")
        if reservation["status"] == "settled":
            settled_reservations += Decimal(reservation["actual_usd"])
        elif reservation["status"] == "reserved":
            outstanding += Decimal(reservation["reserved_usd"])
    expected_settled = Decimal(ledger["imported_prior_spend_usd"]) + settled_reservations
    if Decimal(ledger["settled_spend_usd"]) != expected_settled:
        raise RuntimeError("aggregate spend ledger settled total does not reconcile with its reservations")
    if expected_settled + outstanding > Decimal(ledger["authorized_total_usd"]):
        raise RuntimeError("aggregate spend ledger exceeds its authorized total")


def _unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON object key")
        result[key] = value
    return result


def _write_spend_ledger(path: Path, ledger: dict[str, Any]) -> None:
    payload = (json.dumps(ledger, indent=2, sort_keys=True) + "\n").encode()
    descriptor, temp_name = tempfile.mkstemp(prefix=".aggregate-spend-ledger-", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_name, path)
        directory_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except Exception:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass
        raise


def ledger_totals(ledger: dict[str, Any]) -> dict[str, str]:
    settled = Decimal(ledger["settled_spend_usd"])
    reserved = sum((Decimal(item["reserved_usd"]) for item in ledger["reservations"].values()
                    if item["status"] == "reserved"), Decimal(0))
    authorized = Decimal(ledger["authorized_total_usd"])
    return {
        "authorized_total_usd": str(authorized),
        "settled_spend_usd": str(settled),
        "reserved_usd": str(reserved),
        "remaining_usd": str(max(Decimal(0), authorized - settled - reserved)),
        "prior_spend_is_approximate": "true",
    }


def reserve_aggregate_run(data_dir: Path, run_id: str, case_id: str, amount: Decimal) -> dict[str, str]:
    with spend_ledger(data_dir) as (ledger, save):
        reservations = ledger["reservations"]
        if run_id in reservations:
            raise RuntimeError("aggregate budget run identifier already exists")
        totals = ledger_totals(ledger)
        if amount <= 0 or amount > Decimal(totals["remaining_usd"]):
            raise RuntimeError("aggregate authorization has insufficient unreserved funds for this run")
        reservations[run_id] = {
            "case_id": case_id,
            "status": "reserved",
            "reserved_usd": str(amount),
            "pid": os.getpid(),
            "started_at_unix": int(time.time()),
        }
        save()
        return ledger_totals(ledger)


def aggregate_ledger_snapshot(data_dir: Path) -> tuple[dict[str, str], str]:
    with spend_ledger(data_dir) as (ledger, _save):
        return ledger_totals(ledger), ledger["prior_spend_provenance"]


def settle_aggregate_run(data_dir: Path, run_id: str, actual_cost: Decimal | None) -> dict[str, str]:
    with spend_ledger(data_dir) as (ledger, save):
        reservation = ledger["reservations"].get(run_id)
        if reservation is None or reservation["status"] != "reserved":
            raise RuntimeError("aggregate budget reservation is missing or already terminal")
        if actual_cost is None:
            reservation["status"] = "reserved"  # Preserve full cap when usage is uncertain.
            reservation["uncertain"] = True
        else:
            amount = Decimal(reservation["reserved_usd"])
            if not actual_cost.is_finite() or actual_cost < 0 or actual_cost > amount:
                reservation["uncertain"] = True
                save()
                raise RuntimeError("reported run cost is invalid or exceeds its aggregate reservation")
            reservation["status"] = "settled"
            reservation["actual_usd"] = str(actual_cost)
            ledger["settled_spend_usd"] = str(Decimal(ledger["settled_spend_usd"]) + actual_cost)
        save()
        return ledger_totals(ledger)


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
        runtime = case.get("runtime", {})
        runtime_key = (runtime.get("veasel_version"), runtime.get("veasel_binary_sha256"))
        pinned_rounds = PINNED_VEASEL_RUNTIME_MODEL_ROUNDS.get(runtime_key)
        pinned_requests = (pinned_rounds * PINNED_PROVIDER_HTTP_ATTEMPTS_PER_ROUND
                           if pinned_rounds is not None else None)
        request_cap_matches_runtime = pinned_requests is not None and request_cap == pinned_requests
        bound = (Decimal(request_cap) * (Decimal(context_tokens) * input_rate
                                         + Decimal(output_tokens) * output_rate) / Decimal(1_000_000)
                 if valid_numbers and valid_counts else None)
        safe = valid_numbers and valid_counts and request_cap_matches_runtime and ceiling > 0 and approved > 0 \
            and ceiling <= approved and bound is not None and bound <= ceiling
        report = {
            "approved_spend_usd": str(approved) if approved.is_finite() else "invalid",
            "max_cost_usd": str(ceiling) if ceiling.is_finite() else "invalid",
            "max_model_requests": request_cap if valid_counts else None,
            "pinned_runtime_max_model_rounds": pinned_rounds,
            "pinned_runtime_max_model_requests": pinned_requests,
            "input_usd_per_million_tokens": str(input_rate) if input_rate.is_finite() else "invalid",
            "output_usd_per_million_tokens": str(output_rate) if output_rate.is_finite() else "invalid",
            "worst_case_input_tokens": request_cap * context_tokens if valid_counts else None,
            "worst_case_output_tokens": request_cap * output_tokens if valid_counts else None,
            "conservative_max_cost_usd": str(bound.quantize(Decimal("0.00000001"))) if bound is not None else None,
            "cost_basis": "all input billed at uncached rate; every request uses full context and output caps",
        }
        check("approved_cost_ceiling", safe, report,
              "model request cap matches the exact version/binary runtime round pin x 3 bounded HTTP attempts; positive operator authorization; ceiling <= authorization; worst-case token cost <= ceiling")
        return report, checks
    except (KeyError, InvalidOperation, TypeError, ValueError):
        report = {"cost_basis": "missing or invalid configured-provider cost budget"}
        check("approved_cost_ceiling", False, report, "valid rates, request cap, model limits, and approved spend")
        return report, checks


def responses_proxy_budget(case: dict[str, Any], approved_spend_usd: str | Decimal | None = None) -> dict[str, Any]:
    """Bound generation calls by context/output reservations, never byte estimates."""
    budget = case["cost_budget"]
    max_body_bytes = budget["max_request_body_bytes"]
    configured_attempts = budget["max_model_requests"]
    context_tokens = case["model"]["context_tokens"]
    output_tokens = case["model"]["output_tokens"]
    input_rate = Decimal(str(budget["input_usd_per_million_tokens"]))
    output_rate = Decimal(str(budget["output_usd_per_million_tokens"]))
    case_ceiling = Decimal(str(budget["max_cost_usd"]))
    approved_ceiling = case_ceiling if approved_spend_usd is None else Decimal(str(approved_spend_usd))
    ceiling = min(case_ceiling, approved_ceiling)
    if any(not isinstance(value, int) or isinstance(value, bool) or value <= 0 for value in
           (max_body_bytes, configured_attempts, context_tokens, output_tokens)):
        raise ValueError("Responses proxy token, body, and attempt limits must be positive integers")
    if max_body_bytes < context_tokens:
        raise ValueError("Responses body cap must cover the configured input context")
    per_attempt = (Decimal(context_tokens) * input_rate + Decimal(output_tokens) * output_rate) / Decimal(1_000_000)
    if per_attempt <= 0 or ceiling <= 0:
        raise ValueError("Responses proxy cost rates and ceiling must be positive")
    cost_attempt_limit = int(ceiling // per_attempt)
    attempt_limit = min(configured_attempts, cost_attempt_limit)
    if attempt_limit <= 0:
        raise ValueError("Responses proxy cost ceiling cannot fund one bounded request")
    return {
        "max_request_body_bytes": max_body_bytes,
        "max_input_tokens_per_attempt": context_tokens,
        "max_output_tokens_per_attempt": output_tokens,
        "configured_attempt_limit": configured_attempts,
        "upstream_attempt_limit": attempt_limit,
        "per_attempt_worst_case_cost_usd": str(per_attempt.quantize(Decimal("0.00000001"))),
        "enforced_run_cost_cap_usd": str(min(ceiling, per_attempt * attempt_limit).quantize(Decimal("0.00000001"))),
        "max_cost_usd": str(ceiling),
        "cost_basis": "each generation reserves the pinned context input ceiling at uncached rate plus the full output cap; every attempt is counted",
    }


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


def open_code_config(case: dict[str, Any], responses_base_url: str | None = None,
                     shell_wrapper_path: Path | None = None) -> dict[str, Any]:
    model_name = case["model"]["name"]
    model_id = case["comparators"]["opencode_model"]
    permissions = [{"action": "*", "resource": "*", "effect": "deny"}]
    permissions.extend(
        {"action": action, "resource": "*", "effect": "allow"}
        for action in case["permissions"]["tool_allowlist"]
    )
    permissions.append({"action": "external_directory", "resource": "*", "effect": "deny"})
    provider = case["model"].get("provider")
    shell_wrapper_path = OPEN_CODE_SHELL_WRAPPER if shell_wrapper_path is None else shell_wrapper_path
    shell_wrapper_hash = hashlib.sha256(shell_wrapper_path.read_bytes()).hexdigest()
    expected_shell_hash = case.get("runtime", {}).get("opencode_shell_sandbox_sha256")
    if shell_wrapper_hash != OPEN_CODE_SHELL_WRAPPER_SHA256 \
            or (expected_shell_hash is not None and expected_shell_hash != shell_wrapper_hash):
        raise ValueError("OpenCode shell wrapper does not match the reviewed version pin")
    if provider == "ollama":
        config = {
            "$schema": "https://opencode.ai/config.json",
            "model": model_id,
            "shell": str(shell_wrapper_path),
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
    if not responses_base_url:
        responses_base_url = "http://127.0.0.1:1/v1"
    if not safe_endpoint(responses_base_url) or urlsplit(responses_base_url).hostname not in {
        "127.0.0.1", "localhost", "::1",
    }:
        raise ValueError("Responses provider must use a loopback budget proxy")
    config = {
        "$schema": "https://opencode.ai/config.json",
        "model": model_id,
        "shell": str(shell_wrapper_path),
        "providers": {
            "museproxy": {
                "name": "Muse (budget proxy)",
                "env": ["VEASEL_BENCHMARK_PROXY_KEY"],
                "package": "@opencode/ai/providers/openai-compatible/responses",
                "settings": {
                    "baseURL": responses_base_url,
                    "encoding": "none",
                    "timeout": 300000,
                },
                "models": {
                    model_name: {
                        "name": model_name,
                        "modelID": model_name,
                        "limit": {
                            "context": case["model"]["context_tokens"],
                            "input": case["model"]["context_tokens"],
                            "output": case["model"]["output_tokens"],
                        },
                    },
                },
            },
        },
        "agents": {"build": {"permissions": permissions}},
    }
    if config["model"] != f"museproxy/{model_name}":
        raise ValueError("OpenCode model ID must point to the pinned Responses proxy model")
    return config


def prepare_open_code_config(case: dict[str, Any], data_dir: Path,
                             responses_base_url: str | None = None,
                             shell_wrapper_path: Path | None = None) -> Path:
    config_path = data_dir / "benchmark-opencode.json"
    content = json.dumps(open_code_config(case, responses_base_url, shell_wrapper_path), indent=2) + "\n"
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


def validated_bwrap(path_value: str | Path) -> Path:
    path = Path(path_value).expanduser()
    if not path.is_absolute():
        raise ValueError("Bubblewrap path must be absolute")
    resolved = path.resolve(strict=True)
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise ValueError("Bubblewrap must be an executable regular file")
    return resolved


def wrapped_command(wrapper: Path, command: list[str]) -> list[str]:
    """Pass the agent command to the pinned wrapper using its `--` contract."""
    return [str(wrapper), "--", *command]


def git(workspace: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(workspace), *args], text=True).strip()


def create_task_clone(workspace: Path, base_commit: str, git_home: Path, workspace_parent: Path) -> Path:
    """Create a durable independent task tree without hard-linking baseline files."""
    workspace_parent = persistent_private_directory(workspace_parent)
    task_root = workspace_parent / f"veasel-real-task-{uuid.uuid4().hex}"
    private_directory(git_home)
    templates = private_directory(git_home / "templates")
    git_env = {
        "PATH": os.defpath,
        "HOME": str(git_home),
        "LANG": "C",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_ATTR_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_TEMPLATE_DIR": str(templates),
    }
    subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "clone", "--quiet", "--no-hardlinks",
                    f"--template={templates}", "--no-checkout", str(workspace), str(task_root)],
                   check=True, timeout=120, env=git_env)
    subprocess.run(["git", "-C", str(task_root), "-c", "core.hooksPath=/dev/null",
                    "checkout", "--quiet", "--detach", base_commit],
                   check=True, timeout=60, env=git_env)
    if git(task_root, "rev-parse", "HEAD") != base_commit or task_root.resolve().parent != workspace_parent:
        raise RuntimeError("disposable task clone does not match the pinned base revision")
    return task_root


def validate_task_clone(task_root_value: str | Path | None, base_commit: str,
                        workspace_parent_value: str | Path) -> Path:
    if task_root_value is None:
        raise ValueError("disposable task clone was not supplied")
    task_root = Path(task_root_value).resolve(strict=True)
    workspace_parent = persistent_private_directory(Path(workspace_parent_value))
    if task_root.parent != workspace_parent or not task_root.name.startswith("veasel-real-task-"):
        raise ValueError("task clone must be a direct persistent data_dir/workspaces/veasel-real-task-* child")
    if git(task_root, "rev-parse", "HEAD") != base_commit:
        raise ValueError("task clone does not match the pinned base revision")
    for directory, subdirectories, filenames in os.walk(task_root, followlinks=False):
        subdirectories[:] = [name for name in subdirectories if not (Path(directory) / name).is_symlink()]
        for filename in filenames:
            candidate = Path(directory) / filename
            if not candidate.is_symlink() and candidate.stat().st_nlink > 1:
                raise ValueError("task clone contains a hard-linked regular file")
    return task_root


def preserve_candidate_changes(task_root: Path, base_commit: str, artifact_dir: Path) -> dict[str, Any]:
    """Save tracked diffs and all non-ignored untracked files without cleaning the task clone."""
    patch_path = artifact_dir / "candidate-changes.patch"
    diff = subprocess.check_output(["git", "-C", str(task_root), "diff", "--binary", base_commit, "--"])
    patch_path.write_bytes(diff)
    patch_path.chmod(0o600)
    untracked = subprocess.check_output(
        ["git", "-C", str(task_root), "ls-files", "--others", "--exclude-standard", "-z"]
    ).split(b"\0")
    paths = [item.decode("utf-8", "surrogateescape") for item in untracked if item]
    archive_path = artifact_dir / "candidate-untracked.tar"
    with tarfile.open(archive_path, "w") as archive:
        for relative in paths:
            candidate = task_root / relative
            if candidate.is_symlink():
                archive.add(candidate, arcname=relative, recursive=False)
            elif candidate.is_file():
                archive.add(candidate, arcname=relative, recursive=False)
            elif candidate.is_dir():
                archive.add(candidate, arcname=relative, recursive=True)
    archive_path.chmod(0o600)
    status = git(task_root, "status", "--porcelain=v1", "--untracked-files=all")
    status_path = artifact_dir / "candidate-status.private.txt"
    status_path.write_text(status + "\n")
    status_path.chmod(0o600)
    return {
        "task_clone": str(task_root),
        "patch_artifact": patch_path.name,
        "untracked_archive": archive_path.name,
        "untracked_file_count": len(paths),
        "status_artifact": status_path.name,
        "dirty": bool(status),
    }


def preflight(
    case_path: Path,
    workspace: Path,
    ollama_url: str,
    data_dir: Path,
    agent: str = "veasel",
    agent_binary: str = "veasel",
    approved_spend_usd: str = "0",
    bwrap_path: str | Path = "/usr/bin/bwrap",
    isolation_wrapper_path: str | Path | None = None,
    isolation_wrapper_sha256: str | None = None,
    task_root_value: str | Path | None = None,
) -> dict[str, Any]:
    case, _prompt_path, prompt_hash = load_case(case_path)
    validate_remote_case_pin(case_path, case)
    model = case["model"]
    is_ollama = model.get("provider") == "ollama"
    available, swap = available_resources()
    checks: list[dict[str, Any]] = []

    def check(name: str, ok: bool, actual: Any, required: Any) -> None:
        checks.append({"name": name, "passed": ok, "actual": actual, "required": required})

    try:
        persistent_state = persistent_private_directory(data_dir)
        check("persistent_private_data_dir", True, str(persistent_state),
              "current-user-owned mode-0700 path outside /tmp and /var/tmp")
    except (OSError, ValueError) as exc:
        check("persistent_private_data_dir", False, type(exc).__name__,
              "current-user-owned mode-0700 path outside /tmp and /var/tmp")

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
            shell_path, shell_hash = install_opencode_shell_wrapper(data_dir)
            generated_config = open_code_config(case, shell_wrapper_path=shell_path)
            bwrap = validated_bwrap(bwrap_path)
            check("opencode_shell_wrapper", shell_hash == OPEN_CODE_SHELL_WRAPPER_SHA256,
                  shell_hash, OPEN_CODE_SHELL_WRAPPER_SHA256)
            check("opencode_bwrap", True, str(bwrap), "absolute executable Bubblewrap path")
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
        try:
            totals, provenance = aggregate_ledger_snapshot(data_dir)
            required_run_reservation = Decimal(cost_report.get("conservative_max_cost_usd", "0"))
            aggregate_auth_matches = Decimal(approved_spend_usd) == AUTHORIZED_AGGREGATE_SPEND_USD
            remaining = Decimal(totals["remaining_usd"])
            check("aggregate_spend_ledger", aggregate_auth_matches and remaining >= required_run_reservation,
                  {**totals, "prior_spend_provenance": provenance},
                  {"authorized_total_usd": str(AUTHORIZED_AGGREGATE_SPEND_USD),
                   "minimum_remaining_for_run_usd": str(required_run_reservation)})
        except (OSError, RuntimeError, InvalidOperation, KeyError, TypeError) as exc:
            check("aggregate_spend_ledger", False, type(exc).__name__,
                  "durable private ledger with imported approximate prior spend and available run reservation")
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
        elif agent == "opencode":
            expected_version = case.get("comparators", {}).get("opencode_version")
            expected_model_id = case.get("comparators", {}).get("opencode_model")
            try:
                shell_path, shell_hash = install_opencode_shell_wrapper(data_dir)
                generated_config = open_code_config(case, shell_wrapper_path=shell_path)
                bwrap = validated_bwrap(bwrap_path)
                check("opencode_shell_wrapper", shell_hash == OPEN_CODE_SHELL_WRAPPER_SHA256,
                      shell_hash, OPEN_CODE_SHELL_WRAPPER_SHA256)
                check("opencode_bwrap", True, str(bwrap), "absolute executable Bubblewrap path")
                check("opencode_responses_route", generated_config["model"] == expected_model_id
                      and generated_config["providers"]["museproxy"]["package"]
                      == "@opencode/ai/providers/openai-compatible/responses",
                      {"model": generated_config["model"],
                       "package": generated_config["providers"]["museproxy"]["package"]},
                      {"model": expected_model_id,
                       "package": "@opencode/ai/providers/openai-compatible/responses"})
                config_path = data_dir / "benchmark-opencode.json"
                expected_config_text = json.dumps(generated_config, indent=2) + "\n"
                config_matches = not config_path.exists() or config_path.read_text() == expected_config_text
                check("opencode_private_config", config_matches,
                      "matched_or_absent" if config_matches else "different_config_present",
                      "runner-generated private Responses proxy config")
            except (KeyError, OSError, ValueError) as exc:
                check("opencode_responses_route", False, type(exc).__name__, "pinned Responses proxy route")
            _actual, provider_checks = configured_provider_target(case, data_dir)
            checks.extend(provider_checks)
            try:
                proxy_budget = responses_proxy_budget(case, approved_spend_usd)
                check("responses_proxy_request_limits", proxy_budget["upstream_attempt_limit"] > 0
                      and Decimal(proxy_budget["enforced_run_cost_cap_usd"])
                      <= min(Decimal(proxy_budget["max_cost_usd"]), Decimal(approved_spend_usd)), proxy_budget,
                      "per-call context/output reservations fit within both case and authorized run ceilings")
                check("responses_proxy_cost_bound", True,
                      "token-count precheck plus atomic context/output worst-case reserve and usage settlement",
                      "rejects hosted tools, server-managed history, media, malformed final usage, retries over budget; wrapper still required for egress/token secrecy")
            except (KeyError, InvalidOperation, TypeError, ValueError) as exc:
                check("responses_proxy_request_limits", False, type(exc).__name__, "bounded proxy request limits")
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
                    expected_hash = case.get("comparators", {}).get("opencode_binary_sha256")
                    if expected_hash:
                        actual_hash = hashlib.sha256(Path(binary).read_bytes()).hexdigest()
                        check("opencode_binary_sha256", actual_hash == expected_hash,
                              actual_hash, expected_hash)
                except (OSError, subprocess.CalledProcessError) as exc:
                    check("opencode_version", False, type(exc).__name__, expected_version)
            isolation_ok = False
            isolation_report: dict[str, Any] = {"linux": platform.system() == "Linux"}
            try:
                wrapper, actual_wrapper_hash = validated_isolation_wrapper(argparse.Namespace(
                    isolation_wrapper=isolation_wrapper_path,
                    isolation_wrapper_sha256=isolation_wrapper_sha256,
                ))
                workspace_parent = persistent_private_directory(data_dir / "workspaces")
                task_root = validate_task_clone(task_root_value, case["base_commit"], workspace_parent)
                bwrap = validated_bwrap(bwrap_path)
                shell_path, shell_hash = install_opencode_shell_wrapper(data_dir)
                generated_config = open_code_config(case, shell_wrapper_path=shell_path)
                shell_config = generated_config.get("shell") == str(shell_path)
                isolation_ok = platform.system() == "Linux" and shell_hash == OPEN_CODE_SHELL_WRAPPER_SHA256 \
                    and shell_config and wrapper.is_file() and bool(bwrap) and task_root.is_dir()
                isolation_report.update({
                    "outer_wrapper_sha256": actual_wrapper_hash,
                    "shell_wrapper_sha256": shell_hash,
                    "shell_config_wired": shell_config,
                    "task_root": str(task_root),
                    "task_parent": str(workspace_parent),
                    "bwrap": str(bwrap),
                    "bootstrap_environment_wired": True,
                })
            except (OSError, RuntimeError, ValueError) as exc:
                isolation_report["failure"] = type(exc).__name__
            check("responses_proxy_live_isolation", isolation_ok, isolation_report,
                  "Linux; digest-pinned outer wrapper; pinned OpenCode shell wrapper; valid isolated task clone; executable Bubblewrap")
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
    try:
        validate_remote_case_pin(args.case, case)
    except (OSError, ValueError) as exc:
        print(f"Refusing autonomous run: remote case is not allowlisted ({type(exc).__name__})", file=sys.stderr)
        return 2
    workspace = args.workspace.resolve()
    data_dir = args.data_dir.resolve()
    agent_binary_arg = args.veasel if args.agent == "veasel" else args.opencode
    try:
        persistent_private_directory(data_dir)
        task_parent = persistent_private_directory(data_dir / "workspaces")
        task_root = create_task_clone(workspace, case["base_commit"], data_dir / "git-bootstrap", task_parent)
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as exc:
        print(f"Refusing autonomous run: persistent task workspace setup failed ({type(exc).__name__})", file=sys.stderr)
        return 2
    result = preflight(args.case, workspace, args.ollama_url, data_dir, args.agent,
                       agent_binary_arg, args.approved_spend_usd, getattr(args, "bwrap", Path("/usr/bin/bwrap")),
                       isolation_wrapper, isolation_wrapper_sha256, task_root)
    if not result["passed"]:
        print(json.dumps(result, indent=2))
        return 2
    private_directory(data_dir)
    aggregate_run_id: str | None = None
    aggregate_run_cap: Decimal | None = None
    aggregate_before: dict[str, str] | None = None
    if case["model"].get("provider") != "ollama":
        aggregate_run_id = uuid.uuid4().hex
        if args.agent == "opencode":
            aggregate_run_cap = Decimal(responses_proxy_budget(case, args.approved_spend_usd)[
                "enforced_run_cost_cap_usd"])
        else:
            report, _checks = provider_cost_bound(case, args.approved_spend_usd)
            aggregate_run_cap = Decimal(report["conservative_max_cost_usd"])

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
        command = build_command(args.agent, agent_binary, case, task_root, prompt, trace_path)
    else:
        proxy: BudgetProxy | None = None
        try:
            if case["model"].get("provider") != "ollama":
                upstream_key = private_profile_key(data_dir)
                client_key = secrets.token_urlsafe(32)
                remove_profile_key_from_disk(data_dir)
                proxy_budget = responses_proxy_budget(case, args.approved_spend_usd)
                proxy = BudgetProxy(
                    upstream_base_url=REMOTE_CASE_BASE_URL,
                    api_key=upstream_key,
                    model=REMOTE_CASE_MODEL,
                    max_requests=min(proxy_budget["upstream_attempt_limit"], case["cost_budget"]["max_model_requests"]),
                    context_tokens=REMOTE_CASE_CONTEXT_TOKENS,
                    output_tokens=REMOTE_CASE_OUTPUT_TOKENS,
                    client_api_key=client_key,
                    max_request_body_bytes=proxy_budget["max_request_body_bytes"],
                    max_run_cost_usd=proxy_budget["enforced_run_cost_cap_usd"],
                    input_usd_per_million_tokens=REMOTE_CASE_INPUT_USD_PER_MILLION,
                    output_usd_per_million_tokens=REMOTE_CASE_OUTPUT_USD_PER_MILLION,
                )
                proxy_base_url = proxy.start()
                env["VEASEL_BENCHMARK_PROXY_KEY"] = client_key
            else:
                proxy_base_url = None
            shell_wrapper_path, _shell_wrapper_digest = install_opencode_shell_wrapper(data_dir)
            opencode_config = prepare_open_code_config(case, data_dir, proxy_base_url, shell_wrapper_path)
            env["OPENCODE_CONFIG"] = str(opencode_config)
            env["VEASEL_REAL_TASK_ROOT"] = str(task_root)
            env["VEASEL_REAL_TASK_PARENT"] = str(task_parent)
            env["VEASEL_BWRAP"] = str(validated_bwrap(getattr(args, "bwrap", Path("/usr/bin/bwrap"))))
            for key, name in (("XDG_CONFIG_HOME", "xdg-config"), ("XDG_DATA_HOME", "xdg-data"), ("XDG_CACHE_HOME", "xdg-cache")):
                env[key] = str(private_directory(data_dir / name))
            command = build_command(args.agent, agent_binary, case, task_root, prompt, trace_path)
        except Exception:
            if proxy is not None:
                proxy.close()
            raise
    command = wrapped_command(isolation_wrapper, command)
    started = time.monotonic()
    min_memory = case["budgets"]["minimum_available_memory_bytes"]
    min_swap = case["budgets"]["minimum_free_swap_bytes"]
    samples: list[dict[str, Any]] = []
    outcome = "completed"
    runner_error_type: str | None = None
    proxy_close_error_type: str | None = None
    process_group_terminated: bool | None = None
    previous_handlers: dict[int, Any] = {}
    process: subprocess.Popen[bytes] | None = None
    def request_interrupt(signum: int, _frame: Any) -> None:
        raise KeyboardInterrupt(f"signal {signum}")
    for signum in (signal.SIGINT, signal.SIGTERM):
        previous_handlers[signum] = signal.signal(signum, request_interrupt)
    try:
        with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
            stdout_path.chmod(0o600)
            stderr_path.chmod(0o600)
            if aggregate_run_id is not None and aggregate_run_cap is not None:
                aggregate_before = reserve_aggregate_run(data_dir, aggregate_run_id, case["id"], aggregate_run_cap)
            try:
                process = subprocess.Popen(command, cwd=task_root, env=env, stdout=stdout, stderr=stderr,
                                           start_new_session=True)
            except Exception:
                if aggregate_run_id is not None:
                    settle_aggregate_run(data_dir, aggregate_run_id, Decimal(0))
                raise
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
                    process_group_terminated = terminate_process_group(process)
                    if not process_group_terminated:
                        outcome = "resource_aborted_orphaned"
                    break
                if time.monotonic() - started >= case["budgets"]["wall_seconds"]:
                    outcome = "timeout"
                    process_group_terminated = terminate_process_group(process)
                    if not process_group_terminated:
                        outcome = "timeout_orphaned"
                    break
                sample_delay = 1 - (time.monotonic() - sampled_at)
                if sample_delay > 0:
                    time.sleep(sample_delay)
            try:
                return_code = process.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                process_group_terminated = False
                if not outcome.endswith("_orphaned"):
                    outcome = f"{outcome}_orphaned"
                return_code = 124
    except KeyboardInterrupt:
        outcome = "interrupted"
        if process is None:
            return_code = 130
        else:
            process_group_terminated = terminate_process_group(process)
            if not process_group_terminated:
                outcome = "interrupted_orphaned"
            return_code = process.returncode if process.returncode is not None else 130
    except Exception as exc:
        outcome = "runner_error"
        runner_error_type = type(exc).__name__
        return_code = 1
        if process is not None:
            try:
                process_group_terminated = terminate_process_group(process)
            except Exception:
                process_group_terminated = False
            if process_group_terminated is False:
                outcome = "runner_error_orphaned"
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
        if args.agent == "opencode" and case["model"].get("provider") != "ollama" and proxy is not None:
            try:
                proxy.close()
            except KeyboardInterrupt:
                proxy_close_error_type = "KeyboardInterrupt"
                if outcome == "completed":
                    outcome = "proxy_close_interrupted"
            except Exception as exc:
                proxy_close_error_type = type(exc).__name__
                if outcome == "completed":
                    outcome = "proxy_close_error"
    if outcome == "completed" and return_code != 0:
        outcome = "agent_error"
    try:
        usage = provider_reported_usage(args.agent, trace_path, stdout_path)
    except Exception as exc:
        usage = {"reported": False, "source": "unavailable_after_runner_error", "error": type(exc).__name__}
    try:
        candidate = preserve_candidate_changes(task_root, case["base_commit"], artifact_dir)
    except Exception as exc:
        candidate = {
            "task_clone": str(task_root),
            "dirty": None,
            "preservation_error": type(exc).__name__,
            "workspace_retained": task_root.exists(),
        }
    aggregate_after: dict[str, str] | None = None
    aggregate_status = "not_applicable"
    if aggregate_run_id is not None:
        actual_cost: Decimal | None = None
        if outcome == "completed" and return_code == 0:
            if args.agent == "opencode" and proxy is not None:
                metrics = proxy.metrics()
                if metrics["uncertain_responses"] == 0 and metrics["over_budget_responses"] == 0 \
                        and metrics["generation_cost_in_flight"] == 0 \
                        and metrics["generation_cost_reserved_usd"] == "0.00000000":
                    actual_cost = Decimal(metrics["generation_cost_settled_usd"])
            else:
                estimated = estimate_provider_cost(case, usage)
                if estimated is not None:
                    actual_cost = Decimal(str(estimated))
        try:
            aggregate_after = settle_aggregate_run(data_dir, aggregate_run_id, actual_cost)
            aggregate_status = "settled" if actual_cost is not None else "reserved_uncertain"
        except (OSError, RuntimeError, InvalidOperation, KeyError, TypeError):
            aggregate_status = "ledger_settlement_failed_reserved"
            aggregate_after = None
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
        "runner_error_type": runner_error_type,
        "proxy_close_error_type": proxy_close_error_type,
        "agent_process_group_terminated": process_group_terminated,
        "agent_process_group_orphaned": process_group_terminated is False,
        "wall_ms": int((time.monotonic() - started) * 1000),
        "resource_samples": samples,
        "resource_measurements": resource_measurement_summary(samples),
        "provider_usage": usage,
        "provider_proxy_metrics": proxy.metrics() if args.agent == "opencode" and case["model"].get("provider") != "ollama" else None,
        "estimated_provider_cost_usd": estimate_provider_cost(case, usage),
        "aggregate_spend": {
            "run_id": aggregate_run_id,
            "run_cap_reserved_usd": str(aggregate_run_cap) if aggregate_run_cap is not None else None,
            "ledger_before": aggregate_before,
            "ledger_after": aggregate_after,
            "status": aggregate_status,
            "prior_spend_provenance": IMPORTED_PRIOR_SPEND_NOTE if aggregate_run_id is not None else None,
        },
        "artifacts": {"trace": trace_path.name if args.agent == "veasel" else None,
                      "stdout": stdout_path.name, "stderr": stderr_path.name,
                      "candidate": candidate},
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
        sub.add_argument("--approved-spend-usd", default="5",
                         help="operator-authorized maximum spend for configured remote-provider cases")
        sub.add_argument("--bwrap", type=Path, default=Path("/usr/bin/bwrap"),
                         help="absolute Bubblewrap executable used by the OpenCode shell wrapper")
        sub.add_argument("--isolation-wrapper", type=Path,
                         help="operator-reviewed outer launcher wrapper")
        sub.add_argument("--isolation-wrapper-sha256",
                         help="SHA-256 pin for the operator-reviewed outer launcher wrapper")
        sub.add_argument("--task-root", type=Path,
                         help="existing persistent data-dir/workspaces/veasel-real-task-* clone for preflight")
        if action == "run":
            sub.add_argument("--artifacts", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.action == "preflight":
            agent_binary = args.veasel if args.agent == "veasel" else args.opencode
            report = preflight(args.case, args.workspace.resolve(), args.ollama_url, args.data_dir.resolve(),
                               args.agent, agent_binary, args.approved_spend_usd, args.bwrap,
                               args.isolation_wrapper, args.isolation_wrapper_sha256, args.task_root)
            print(json.dumps(report, indent=2))
            return 0 if report["passed"] else 2
        return run_case(args)
    except (OSError, subprocess.CalledProcessError, KeyError, ValueError, json.JSONDecodeError) as exc:
        print(f"preflight error: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
