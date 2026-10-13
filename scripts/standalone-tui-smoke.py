#!/usr/bin/env python3
"""Exercise the packaged standalone TUI against an isolated local Veasel server."""

from __future__ import annotations

import argparse
import fcntl
import os
import pty
import re
import select
import signal
import socket
import struct
import subprocess
import tempfile
import termios
import time
from pathlib import Path
from urllib.request import urlopen


def wait_for_server(process: subprocess.Popen[bytes], port: int) -> None:
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"Veasel backend exited early with {process.returncode}")
        try:
            with urlopen(f"http://127.0.0.1:{port}/v1/health", timeout=0.5) as response:
                if response.status == 200:
                    return
        except OSError:
            time.sleep(0.05)
    raise TimeoutError("Veasel backend did not become healthy within 15 seconds")


def run_tui(tui_path: Path, env: dict[str, str]) -> None:
    child, terminal = pty.fork()
    if child == 0:
        os.execve(tui_path, [str(tui_path)], env)

    fcntl.ioctl(terminal, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
    output = bytearray()

    def visible_output() -> bytes:
        return re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07]*(?:\x07|\x1b\\)", b"", output)

    def wait_for_markers(markers: tuple[bytes, ...], timeout: float, description: str) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            readable, _, _ = select.select([terminal], [], [], 0.1)
            if readable:
                try:
                    output.extend(os.read(terminal, 65_536))
                except OSError:
                    break
                visible = visible_output()
                if all(marker in visible for marker in markers):
                    return
            finished, status = os.waitpid(child, os.WNOHANG)
            if finished:
                raise RuntimeError(f"standalone TUI exited before {description} (status={status})")
        snippet = visible_output()[-2_000:].decode(errors="replace")
        raise TimeoutError(
            f"standalone TUI did not reach {description} within {timeout} seconds; "
            f"visible terminal output: {snippet}"
        )

    try:
        wait_for_markers((b"connected", b"SESSIONS", b"VEASEL"), 10, "its connected session screen")

        os.write(terminal, b"s")
        wait_for_markers((b"MODEL SETTINGS", "● All".encode()), 5, "provider settings")
        for _ in range(4):
            os.write(terminal, b"\t")
            deadline = time.monotonic() + 0.2
            while time.monotonic() < deadline:
                readable, _, _ = select.select([terminal], [], [], 0.05)
                if readable:
                    try:
                        output.extend(os.read(terminal, 65_536))
                    except OSError:
                        break
                finished, status = os.waitpid(child, os.WNOHANG)
                if finished:
                    raise RuntimeError(f"standalone TUI exited while cycling provider groups (status={status})")

        os.write(terminal, b"\x1b")
        time.sleep(0.1)
        os.write(terminal, b"q")

        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            finished, status = os.waitpid(child, os.WNOHANG)
            if finished:
                if os.waitstatus_to_exitcode(status) != 0:
                    raise RuntimeError(f"standalone TUI exited unsuccessfully (status={status})")
                return
            time.sleep(0.01)
        raise TimeoutError("standalone TUI did not exit after the quit key")
    finally:
        try:
            os.close(terminal)
        except OSError:
            pass
        try:
            os.kill(child, 0)
        except ProcessLookupError:
            pass
        else:
            try:
                os.kill(child, signal.SIGINT)
            except ProcessLookupError:
                pass
            else:
                deadline = time.monotonic() + 2
                finished = False
                while time.monotonic() < deadline:
                    try:
                        waited, _ = os.waitpid(child, os.WNOHANG)
                    except ChildProcessError:
                        finished = True
                        break
                    if waited:
                        finished = True
                        break
                    time.sleep(0.02)
                if not finished:
                    try:
                        os.kill(child, signal.SIGKILL)
                        os.waitpid(child, 0)
                    except ProcessLookupError:
                        pass


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", required=True, type=Path)
    parser.add_argument("--tui", required=True, type=Path)
    args = parser.parse_args()
    server_path = args.server.resolve(strict=True)
    tui_path = args.tui.resolve(strict=True)

    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]

    with tempfile.TemporaryDirectory(prefix="veasel-tui-smoke-") as temporary:
        data_dir = Path(temporary) / "data"
        plugin_dir = Path(temporary) / "plugins"
        env = os.environ.copy()
        env.update(
            VEASEL_PORT=str(port),
            VEASEL_DATA_DIR=str(data_dir),
            VEASEL_PLUGIN_DIR=str(plugin_dir),
            VEASEL_API_URL=f"http://127.0.0.1:{port}",
            TERM="xterm-256color",
        )
        for name in list(env):
            if any(marker in name for marker in ("API_KEY", "_TOKEN", "_PAT", "_SECRET_KEY")):
                env.pop(name)
        server = subprocess.Popen(
            [str(server_path), "serve"],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            wait_for_server(server, port)
            run_tui(tui_path, env)
        finally:
            if server.poll() is None:
                server.send_signal(signal.SIGINT)
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait(timeout=5)

    print("Standalone TUI connected to an isolated Veasel backend and exited cleanly.")


if __name__ == "__main__":
    main()
