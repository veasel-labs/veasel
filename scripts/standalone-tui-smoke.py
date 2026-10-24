#!/usr/bin/env python3
"""Exercise the packaged standalone TUI against an isolated local Veasel server."""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.request import Request
from urllib.request import urlopen

if os.name == "nt":
    from windows_conpty import run_tui_conpty
else:
    import fcntl
    import pty
    import select
    import signal
    import struct
    import termios


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


def wait_for_persisted_reply(api_base: str, session_id: str) -> None:
    deadline = time.monotonic() + 30
    url = f"{api_base}/v1/sessions/{session_id}/messages"
    while time.monotonic() < deadline:
        with urlopen(url, timeout=5) as response:
            messages = json.load(response)
        if any(
            message.get("role") == "assistant" and message.get("content") == "Provider fixture reply"
            for message in messages
        ):
            return
        time.sleep(0.05)
    raise TimeoutError("mock provider response was rendered but not persisted by the backend")


def run_tui(tui_path: Path, env: dict[str, str], session_title: str, session_id: str) -> None:
    if os.name == "nt":
        run_tui_conpty(tui_path, env, session_title, session_id, wait_for_persisted_reply)
        return

    child, terminal = pty.fork()
    if child == 0:
        os.execve(tui_path, [str(tui_path)], env)

    fcntl.ioctl(terminal, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
    output = bytearray()

    def visible_output() -> bytes:
        return re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[_PXM][^\x1b]*\x1b\\", b"", output)

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
        wait_for_markers(
            (b"connected", b"SESSIONS", b"VEASEL", session_title.encode()),
            10,
            "its connected screen with the seeded session",
        )

        os.write(terminal, b"s")
        wait_for_markers((b"MODEL SETTINGS", "● All".encode()), 5, "provider settings")
        for _ in range(5):
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

        output.clear()
        os.write(terminal, b"anthorpic")
        wait_for_markers((b"1/210", b"Anthropic"), 5, "typo-tolerant provider search")

        # Wait for a new home frame after Escape, never a marker from an older screen.
        output.clear()
        os.write(terminal, b"\x1b")
        wait_for_markers((b"SESSIONS", b"q quit"), 5, "the home session list after leaving settings")

        output.clear()
        os.write(terminal, b"\r")
        wait_for_markers((b"Message Veasel",), 5, "the selected session composer")
        output.clear()
        os.write(terminal, b"Say hello\r")
        wait_for_markers((b"Provider fixture reply",), 30, "the mock provider response in the transcript")
        wait_for_persisted_reply(env["VEASEL_API_URL"], session_id)
        output.clear()
        os.write(terminal, b"\x10")
        wait_for_markers((b"Commands",), 5, "the command palette after the assistant reply")
        output.clear()
        os.write(terminal, b"quit")
        wait_for_markers((b"Quit",), 5, "the quit command in the palette")
        os.write(terminal, b"\r")

        def wait_exit(timeout: float) -> int | None:
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                finished, status = os.waitpid(child, os.WNOHANG)
                if finished:
                    return status
                readable, _, _ = select.select([terminal], [], [], 0.01)
                if readable:
                    try:
                        output.extend(os.read(terminal, 65_536))
                    except OSError:
                        pass
            return None

        status = wait_exit(5)
        if status is not None:
            if os.waitstatus_to_exitcode(status) != 0:
                raise RuntimeError(f"standalone TUI exited unsuccessfully after the Quit command (status={status})")
            return
        snippet = visible_output()[-2_500:].decode(errors="replace")
        raise TimeoutError(f"standalone TUI did not exit after the Quit command: {snippet}")
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
        workspace = Path(temporary) / "workspace"
        workspace.mkdir()
        env = os.environ.copy()
        for name in list(env):
            if any(marker in name for marker in ("API_KEY", "_TOKEN", "_PAT", "_SECRET_KEY")):
                env.pop(name)
        provider_port_file = Path(temporary) / "provider.port"
        provider = subprocess.Popen(
            [sys.executable, str(Path(__file__).with_name("mock-provider.py")), str(provider_port_file)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
        )
        deadline = time.monotonic() + 5
        while not provider_port_file.exists() and time.monotonic() < deadline:
            if provider.poll() is not None:
                raise RuntimeError("mock provider exited before becoming ready")
            time.sleep(0.05)
        if not provider_port_file.exists():
            provider.terminate()
            provider.wait(timeout=5)
            raise RuntimeError("mock provider did not become ready")
        env.update(
            VEASEL_PORT=str(port),
            VEASEL_DATA_DIR=str(data_dir),
            VEASEL_PLUGIN_DIR=str(plugin_dir),
            VEASEL_API_URL=f"http://127.0.0.1:{port}",
            VEASEL_PROJECT_DIR=str(workspace),
            VEASEL_MODEL_PROVIDER="openai-compatible",
            VEASEL_MODEL="smoke-model",
            VEASEL_MODEL_BASE_URL=f"http://127.0.0.1:{provider_port_file.read_text().strip()}/v1",
            OPENAI_API_KEY="veasel-openai-key",
            TERM="xterm-256color",
        )
        server: subprocess.Popen[bytes] | None = None
        try:
            server = subprocess.Popen(
                [str(server_path), "serve"],
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            wait_for_server(server, port)
            session_title = "TUI round-trip smoke"
            request = Request(
                f"http://127.0.0.1:{port}/v1/sessions",
                data=json.dumps({"title": session_title, "directory": str(workspace)}).encode(),
                headers={"content-type": "application/json"},
            )
            with urlopen(request, timeout=5) as response:
                if response.status != 201:
                    raise RuntimeError(f"backend did not create the TUI smoke session: HTTP {response.status}")
                session_id = json.load(response)["id"]
            run_tui(tui_path, env, session_title, session_id)
            with urlopen(f"http://127.0.0.1:{port}/v1/sessions/{session_id}/messages", timeout=5) as response:
                messages = json.load(response)
            persisted = {(message.get("role"), message.get("content")) for message in messages}
            if ("user", "Say hello") not in persisted or ("assistant", "Provider fixture reply") not in persisted:
                raise RuntimeError(f"TUI conversation was not persisted correctly: {messages!r}")
        finally:
            if server is not None and server.poll() is None:
                if os.name == "nt":
                    server.terminate()
                else:
                    server.send_signal(signal.SIGINT)
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait(timeout=5)
            if provider.poll() is None:
                provider.terminate()
            try:
                provider.wait(timeout=5)
            except subprocess.TimeoutExpired:
                provider.kill()
                provider.wait(timeout=5)

    print("Standalone TUI completed a mock-provider conversation through the isolated backend.")


if __name__ == "__main__":
    main()
