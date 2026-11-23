#!/usr/bin/env python3
"""Outer Linux sandbox for budgeted real-task provider runs.

This wrapper hides host home/runtime mounts, gives the agent one disposable
workspace and private run state, and creates an isolated network namespace.
The only optional network path is a private Unix socket forwarded to the
loopback BudgetProxy by proxy_network_bridge.py. Shell tools receive a second
network namespace from opencode-shell-sandbox.sh and do not inherit that mount.
"""

from __future__ import annotations

import os
import hashlib
import stat
import subprocess
import sys
from pathlib import Path
from typing import Sequence


STATE_GUEST = Path("/tmp/veasel-state")
WORKSPACE_PARENT_GUEST = Path("/run/veasel-workspace-parent")
ARTIFACTS_GUEST = Path("/tmp/veasel-artifacts")
RELAY_DIR_GUEST = Path("/tmp/veasel-proxy")
TOOLS_GUEST = Path("/tmp/veasel-tools")
PROXY_PORT = 18765
EXPECTED_PROXY_BRIDGE_SHA256 = "a4c1a741828b69bd267acf138ccba49635e59eec13080c0a7ed74ea8884ab254"


def _private_owned_directory(value: str, label: str) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        raise ValueError(f"{label} must be absolute")
    resolved = path.resolve(strict=True)
    info = resolved.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise ValueError(f"{label} must be an owned directory with mode 0700")
    if label == "task parent" and any(
        resolved == temporary or temporary in resolved.parents
        for temporary in (Path("/tmp"), Path("/var/tmp"))
    ):
        raise ValueError("task parent must be persistent and outside temporary directories")
    return resolved


def _task_paths() -> tuple[Path, Path]:
    task_value = os.environ.get("VEASEL_REAL_TASK_ROOT", "")
    parent_value = os.environ.get("VEASEL_REAL_TASK_PARENT", "")
    if not task_value or not parent_value:
        raise ValueError("task root and task parent are required")
    parent = _private_owned_directory(parent_value, "task parent")
    task = Path(task_value).resolve(strict=True)
    if not task.is_dir() or task.parent != parent or not task.name.startswith("veasel-real-task-"):
        raise ValueError("task root must be a direct veasel-real-task-* child of the private parent")
    return task, parent


def _add_guest_binary_mounts(command: Sequence[str], mounts: list[str]) -> Path:
    executable_value = command[0]
    executable = Path(executable_value)
    if not executable.is_absolute():
        raise ValueError("agent executable must be an absolute path")
    executable = executable.resolve(strict=True)
    metadata = executable.stat()
    if not stat.S_ISREG(metadata.st_mode) or not os.access(executable, os.X_OK):
        raise ValueError("agent executable must be an executable regular file")
    hidden_root = next((root for root in (Path("/home"), Path("/opt")) if root in executable.parents), None)
    if hidden_root is not None:
        current = hidden_root
        for part in executable.parent.relative_to(hidden_root).parts:
            current /= part
            mounts.extend(["--dir", str(current)])
        mounts.extend(["--ro-bind", str(executable), str(executable)])
    return executable


def _rewrite_argument(argument: str, task: Path, artifacts: Path) -> str:
    if argument == str(task):
        return str(WORKSPACE_PARENT_GUEST / task.name)
    try:
        relative = Path(argument).relative_to(artifacts)
    except ValueError:
        return argument
    return str(ARTIFACTS_GUEST / relative)


def _guest_environment(state: Path, task: Path) -> dict[str, str]:
    allowed = {"LANG", "LC_ALL", "TERM"}
    guest = {key: value for key, value in os.environ.items()
             if key in allowed or key.startswith("LC_")}
    guest.update({
        "PATH": "/usr/bin:/bin",
        "HOME": str(STATE_GUEST / "home"),
        "TMPDIR": str(STATE_GUEST / "tmp"),
        "XDG_CONFIG_HOME": str(STATE_GUEST / "xdg-config"),
        "XDG_DATA_HOME": str(STATE_GUEST / "xdg-data"),
        "XDG_CACHE_HOME": str(STATE_GUEST / "xdg-cache"),
        "VEASEL_DATA_DIR": str(STATE_GUEST / "veasel-data"),
        "VEASEL_PLUGIN_DIR": str(STATE_GUEST / "plugins"),
        "VEASEL_REAL_TASK_ROOT": str(WORKSPACE_PARENT_GUEST / task.name),
        "VEASEL_REAL_TASK_PARENT": str(WORKSPACE_PARENT_GUEST),
        "VEASEL_BWRAP": os.environ.get("VEASEL_BWRAP", "/usr/bin/bwrap"),
        "OPENCODE_CONFIG": str(STATE_GUEST / "benchmark-opencode.json"),
    })
    if os.environ.get("VEASEL_BENCHMARK_AGENT") == "opencode":
        proxy_key = os.environ.get("VEASEL_BENCHMARK_PROXY_KEY", "")
        if proxy_key:
            guest["VEASEL_BENCHMARK_PROXY_KEY"] = proxy_key
    for key in (
        "VEASEL_PORT", "VEASEL_MODEL_CONTEXT_TOKENS", "VEASEL_MODEL_MAX_OUTPUT_TOKENS",
        "VEASEL_ALLOW_AUTONOMOUS_EXECUTION",
    ):
        if key in os.environ:
            guest[key] = os.environ[key]
    # Provider credentials belong in the private Veasel model profile, never
    # in the process environment inherited by shell or MCP child processes.
    if os.environ.get("VEASEL_MODEL_API_KEY"):
        raise ValueError("direct provider credentials are not allowed by this proxy-only sandbox")
    return guest


def build_bwrap_command(command: Sequence[str]) -> tuple[list[str], dict[str, str]]:
    if not command:
        raise ValueError("agent command is required")
    if os.name != "posix" or not sys.platform.startswith("linux"):
        raise ValueError("budgeted benchmark sandbox requires Linux")
    task, _task_parent = _task_paths()
    state = _private_owned_directory(os.environ.get("VEASEL_BENCHMARK_STATE_DIR", ""), "run state")
    artifacts = _private_owned_directory(os.environ.get("VEASEL_BENCHMARK_ARTIFACTS", ""), "artifact directory")
    relay_socket_value = os.environ.get("VEASEL_BENCHMARK_PROXY_SOCKET", "")
    if not relay_socket_value:
        raise ValueError("budget proxy Unix socket is required")
    relay_socket = Path(relay_socket_value).expanduser()
    if not relay_socket.is_absolute():
        raise ValueError("budget proxy Unix socket path must be absolute")
    relay_socket = relay_socket.resolve(strict=True)
    relay_info = relay_socket.stat()
    if not stat.S_ISSOCK(relay_info.st_mode) or relay_info.st_uid != os.getuid() \
            or stat.S_IMODE(relay_info.st_mode) != 0o600:
        raise ValueError("budget proxy socket must be owned by this user with mode 0600")
    relay_dir = relay_socket.parent
    if relay_dir.stat().st_uid != os.getuid() or stat.S_IMODE(relay_dir.stat().st_mode) != 0o700:
        raise ValueError("budget proxy socket directory must be owned by this user with mode 0700")

    bwrap_value = os.environ.get("VEASEL_BWRAP", "/usr/bin/bwrap")
    bwrap = Path(bwrap_value).expanduser()
    if not bwrap.is_absolute() or not bwrap.is_file() or not os.access(bwrap, os.X_OK):
        raise ValueError("Bubblewrap must be an absolute executable path")
    bridge_value = os.environ.get("VEASEL_BENCHMARK_BRIDGE_SCRIPT", "")
    bridge = Path(bridge_value).resolve(strict=True)
    if not bridge.is_file():
        raise ValueError("budget proxy bridge script is missing")
    bridge_sha256 = hashlib.sha256(bridge.read_bytes()).hexdigest()
    if bridge_sha256 != EXPECTED_PROXY_BRIDGE_SHA256:
        raise ValueError("budget proxy bridge does not match the reviewed source pin")
    if not os.environ.get("VEASEL_BENCHMARK_PROXY_KEY"):
        raise ValueError("budget proxy client credential is required")

    workspace_mirror = state / "workspace-parent"
    workspace_mirror.mkdir(mode=0o700, exist_ok=True)
    workspace_mirror.chmod(0o700)
    task_mountpoint = workspace_mirror / task.name
    task_mountpoint.mkdir(mode=0o700, exist_ok=True)
    task_mountpoint.chmod(0o700)

    mounts: list[str] = [
        "--unshare-all", "--die-with-parent", "--new-session",
        "--ro-bind", "/", "/", "--proc", "/proc", "--dev", "/dev",
        "--tmpfs", "/etc", "--tmpfs", "/home", "--tmpfs", "/root", "--tmpfs", "/run",
        "--tmpfs", "/tmp", "--tmpfs", "/var", "--tmpfs", "/opt", "--tmpfs", "/srv",
        "--tmpfs", "/mnt",
        "--dir", str(STATE_GUEST), "--bind", str(state), str(STATE_GUEST),
        "--dir", str(WORKSPACE_PARENT_GUEST), "--bind", str(workspace_mirror),
        str(WORKSPACE_PARENT_GUEST),
        "--bind", str(task), str(WORKSPACE_PARENT_GUEST / task.name),
        "--dir", str(ARTIFACTS_GUEST), "--bind", str(artifacts), str(ARTIFACTS_GUEST),
        "--dir", str(RELAY_DIR_GUEST), "--ro-bind", str(relay_dir), str(RELAY_DIR_GUEST),
        "--dir", str(TOOLS_GUEST), "--ro-bind", str(bridge), str(TOOLS_GUEST / bridge.name),
    ]
    executable = _add_guest_binary_mounts(command, mounts)

    remapped = [_rewrite_argument(arg, task, artifacts) for arg in command]
    remapped[0] = str(executable)
    guest = _guest_environment(state, task)
    # If the binary was installed under the hidden home directory, the exact
    # executable file is re-mounted read-only at its original absolute path.
    namespace_command = [
        "/usr/bin/python3", str(TOOLS_GUEST / bridge.name),
        "--socket", str(RELAY_DIR_GUEST / relay_socket.name),
        "--port", str(PROXY_PORT), "--", *remapped,
    ]
    # Relay implementation details are only needed by this outer launcher.
    # The agent receives neither the socket path nor the proxy credential.
    bwrap_command = [str(bwrap), *mounts, "--chdir", guest["VEASEL_REAL_TASK_ROOT"],
                     "--", *namespace_command]
    return bwrap_command, guest


def main(argv: Sequence[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    if not arguments or arguments[0] != "--" or len(arguments) == 1:
        print("expected -- <agent argv>", file=sys.stderr)
        return 64
    try:
        command, env = build_bwrap_command(arguments[1:])
        completed = subprocess.run(command, env=env, check=False)
        return completed.returncode
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as exc:
        print(f"benchmark isolation refused: {type(exc).__name__}", file=sys.stderr)
        return 69


if __name__ == "__main__":
    raise SystemExit(main())
