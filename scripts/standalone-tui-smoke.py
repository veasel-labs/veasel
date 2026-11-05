#!/usr/bin/env python3
"""Exercise the packaged standalone TUI against an isolated local Veasel server."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import socket
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import quote
from urllib.request import Request
from urllib.request import urlopen

from terminal_screen import TerminalScreen

# Attempts to open the command palette, filter it, and confirm the Quit option
# before the smoke gives up. Each attempt starts from a clean palette state.
_PALETTE_RETRIES = 3

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


def wait_for_persisted_reply(api_base: str, session_id: str, expected_reply: str = "Provider fixture reply") -> None:
    deadline = time.monotonic() + 30
    url = f"{api_base}/v1/sessions/{session_id}/messages"
    while time.monotonic() < deadline:
        with urlopen(url, timeout=5) as response:
            messages = json.load(response)
        if any(
            message.get("role") == "assistant" and message.get("content") == expected_reply
            for message in messages
        ):
            return
        time.sleep(0.05)
    raise TimeoutError("mock provider response was rendered but not persisted by the backend")


def api_json(port: int, method: str, path: str, body: dict[str, str] | None = None) -> dict[str, object]:
    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = Request(
        f"http://127.0.0.1:{port}{path}",
        data=data,
        method=method,
        headers={"content-type": "application/json"} if data is not None else {},
    )
    with urlopen(request, timeout=5) as response:
        return json.load(response)


def create_review_fixture(port: int, temporary: Path) -> tuple[str, str, Path, str]:
    workspace = temporary / "review-workspace"
    workspace.mkdir()
    (workspace / "review.txt").write_text("before\n", encoding="utf-8")
    session = api_json(
        port,
        "POST",
        "/v1/sessions",
        {"title": "TUI review smoke", "directory": str(workspace)},
    )
    session_id = str(session["id"])
    edit = api_json(
        port,
        "POST",
        f"/v1/sessions/{quote(session_id, safe='')}/workspace/edits",
        {"path": "review.txt", "content": "before\napproved-by-tui\n"},
    )
    if edit.get("status") != "pending" or "+approved-by-tui" not in str(edit.get("diff", "")):
        raise RuntimeError(f"backend did not create the pending TUI review fixture: {edit}")
    return session_id, str(edit["id"]), workspace, "before\napproved-by-tui\n"


def run_tui(
    tui_path: Path,
    env: dict[str, str],
    session_title: str | None = None,
    session_id: str | None = None,
    review_path: bytes | None = None,
    recovery_only: bool = False,
) -> float:
    if os.name == "nt":
        return run_tui_conpty(
            tui_path, env, session_title, session_id, wait_for_persisted_reply, review_path, recovery_only,
        )

    started = time.monotonic()
    child, terminal = pty.fork()
    if child == 0:
        os.execve(tui_path, [str(tui_path)], env)

    fcntl.ioctl(terminal, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
    output = bytearray()
    screen = TerminalScreen(rows=24, cols=100)

    def record(chunk: bytes) -> None:
        output.extend(chunk)
        screen.feed(chunk)

    def visible_output() -> bytes:
        return re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[_PXM][^\x1b]*\x1b\\", b"", output)

    def wait_for_markers(markers: tuple[bytes, ...], timeout: float, description: str) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            readable, _, _ = select.select([terminal], [], [], 0.1)
            if readable:
                try:
                    record(os.read(terminal, 65_536))
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

    def wait_for_screen_markers(
        markers: tuple[bytes, ...],
        timeout: float,
        description: str,
        absent: tuple[bytes, ...] = (),
    ) -> None:
        # Differential repaints emit only changed cells, so a placeholder
        # transition (Restoring… -> Message Veasel…) may never appear as a
        # contiguous raw byte string even though the on-screen composer is
        # ready (macOS CI run 41923796968). Assert against the rendered
        # screen instead, and require stale-state text to be gone.
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            readable, _, _ = select.select([terminal], [], [], 0.1)
            if readable:
                try:
                    record(os.read(terminal, 65_536))
                except OSError:
                    break
                rendered = screen.text().encode()
                if all(marker in rendered for marker in markers) and not any(
                    marker in rendered for marker in absent
                ):
                    return
                if all(marker in visible_output() for marker in markers):
                    return
            finished, status = os.waitpid(child, os.WNOHANG)
            if finished:
                raise RuntimeError(f"standalone TUI exited before {description} (status={status})")
        raise TimeoutError(
            f"standalone TUI did not reach {description} within {timeout} seconds; "
            f"rendered screen:\n{screen.text()}"
        )

    def wait_for_partial_reply(partial: bytes, complete: bytes, timeout: float) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            readable, _, _ = select.select([terminal], [], [], 0.05)
            if readable:
                try:
                    record(os.read(terminal, 65_536))
                except OSError:
                    break
                if partial in output:
                    if complete in output:
                        raise RuntimeError("standalone TUI received the complete reply before the partial-stream check")
                    return
            finished, status = os.waitpid(child, os.WNOHANG)
            if finished:
                raise RuntimeError(f"standalone TUI exited before rendering partial streamed text (status={status})")
        snippet = visible_output()[-2_000:].decode(errors="replace")
        raise TimeoutError(f"standalone TUI did not render partial streamed text within {timeout} seconds: {snippet}")

    def quit_via_palette(palette_description: str, quit_description: str) -> None:
        # The palette focuses its filter input asynchronously after the frame renders
        # (onMount -> queueMicrotask), so keystrokes sent too early are dropped and the
        # list stays unfiltered; CI hit this on both Linux and macOS. Give the focus a
        # moment to land before typing. On a failed quit wait, close the palette with
        # Escape and let the dialog fully unmount before reopening: an immediate Ctrl+P
        # is consumed by the palette's own toggle handler while it is still mounted,
        # which leaves the palette closed and fails the next open wait.
        last_snippet = ""
        for attempt in range(_PALETTE_RETRIES):
            output.clear()
            os.write(terminal, b"\x10")
            try:
                wait_for_markers(
                    (b"Commands", b"Filter commands"), 5, f"{palette_description} (attempt {attempt + 1})",
                )
            except TimeoutError as error:
                # A preceding dialog (e.g. review approval) can still hold
                # keyboard focus when Ctrl+P lands, swallowing the toggle.
                # Reset to a clean state and retry like the filter wait below.
                last_snippet = str(error)
                os.write(terminal, b"\x1b")
                time.sleep(0.5)
                continue
            time.sleep(0.3)
            output.clear()
            os.write(terminal, b"quit")
            try:
                wait_for_markers((b"Quit",), 5, quit_description)
            except TimeoutError:
                last_snippet = visible_output()[-2_000:].decode(errors="replace")
                os.write(terminal, b"\x1b")
                time.sleep(0.5)
                continue
            os.write(terminal, b"\r")
            return
        raise TimeoutError(
            f"standalone TUI did not reach {quit_description} after {_PALETTE_RETRIES} attempts; "
            f"visible terminal output: {last_snippet}"
        )

    try:
        home_markers = (b"connected", b"SESSIONS", b"VEASEL")
        if session_title:
            home_markers = (*home_markers, session_title.encode())
        wait_for_markers(home_markers, 10, "its connected session screen")
        startup_ms = (time.monotonic() - started) * 1000

        os.write(terminal, b"s")
        wait_for_markers((b"MODEL SETTINGS", b"All 210/210"), 5, "provider settings")
        for _ in range(5):
            os.write(terminal, b"\t")
            deadline = time.monotonic() + 0.2
            while time.monotonic() < deadline:
                readable, _, _ = select.select([terminal], [], [], 0.05)
                if readable:
                    try:
                        record(os.read(terminal, 65_536))
                    except OSError:
                        break
                finished, status = os.waitpid(child, os.WNOHANG)
                if finished:
                    raise RuntimeError(f"standalone TUI exited while cycling provider groups (status={status})")

        output.clear()
        os.write(terminal, b"anthorpic")
        wait_for_markers((b"1/210", b"Anthropic"), 5, "typo-tolerant provider search")

        # Exercise the packaged TUI, not only a mocked component: the filter
        # previously swallowed leading j/k/g and numeric keys as navigation.
        # Verify that Ctrl+L resets the query and that both alphabetic and
        # numeric-prefix providers remain discoverable after a fresh search.
        for query, result_label in (
            (b"gemini", b"Google Gemini"),
            (b"kimi", b"Kimi For Coding"),
            (b"302", b"302.AI"),
        ):
            output.clear()
            os.write(terminal, b"\x0c")  # Ctrl+L: clear filter
            wait_for_markers((b"All 210/210",), 5, "the cleared provider filter")
            output.clear()
            os.write(terminal, query)
            wait_for_markers((result_label,), 5, f"provider filter query {query!r}")

        # Wait for a new home frame after Escape, never a marker from an older screen.
        output.clear()
        os.write(terminal, b"\x1b")
        wait_for_markers((b"SESSIONS", b"q quit"), 5, "the home session list after leaving settings")

        if review_path:
            output.clear()
            os.write(terminal, b"\r")
            wait_for_markers((b"TUI review smoke",), 5, "the seeded review session")
            output.clear()
            os.write(terminal, b"\x12")
            wait_for_markers((b"REVIEW WORKSPACE EDIT", review_path), 5, "the live workspace edit review")
            output.clear()
            os.write(terminal, b"a")
            wait_for_screen_markers((b"Message Veasel",), 5, "the session after its only review was approved")
            quit_via_palette(
                "the command palette after the only review was approved", "the command palette quit option",
            )
        elif not session_id:
            os.write(terminal, b"q")
        elif recovery_only:
            # Reopen the persisted session against the restarted backend:
            # the prior transcript must render and the composer must become
            # ready again, without sending anything new.
            time.sleep(0.25)
            output.clear()
            os.write(terminal, b"\r")
            wait_for_screen_markers(
                (b"two pieces", b"Message Veasel"), 10, "the session recovered after backend restart",
                absent=(b"Restoring this session",),
            )
            quit_via_palette(
                "the command palette after backend restart recovery", "the quit command in the palette",
            )
        else:
            # Escape can expose the home frame before the settings dialog has
            # fully released keyboard focus. Sending Enter in that same tick
            # occasionally leaves the CI smoke at home rather than selecting
            # the seeded session. Let the dialog teardown/focus settle first.
            time.sleep(0.25)
            output.clear()
            os.write(terminal, b"\r")
            # Recovery uses a different placeholder until submissions are safe.
            # This remains a hard readiness assertion for the packaged binary,
            # but permits normal asynchronous backend startup under CI load.
            wait_for_screen_markers(
                (b"Message Veasel",), 10, "the recovered session composer",
                absent=(b"Restoring this session",),
            )
            output.clear()
            os.write(terminal, b"Stream incrementally\r")
            wait_for_partial_reply(b"Streaming fixture", b"Streaming fixture reply arrives in two pieces", 15)
            wait_for_markers((b"arrives in two pieces",), 30, "the mock provider response in the transcript")
            wait_for_persisted_reply(env["VEASEL_API_URL"], session_id, "Streaming fixture reply arrives in two pieces")
            quit_via_palette(
                "the command palette after the assistant reply", "the quit command in the palette",
            )

        def wait_exit(timeout: float) -> int | None:
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                finished, status = os.waitpid(child, os.WNOHANG)
                if finished:
                    return status
                readable, _, _ = select.select([terminal], [], [], 0.01)
                if readable:
                    try:
                        record(os.read(terminal, 65_536))
                    except OSError:
                        pass
            return None

        status = wait_exit(5)
        if status is not None:
            if os.waitstatus_to_exitcode(status) != 0:
                raise RuntimeError(f"standalone TUI exited unsuccessfully after the Quit command (status={status})")
            return startup_ms
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


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as binary:
        for chunk in iter(lambda: binary.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_build_provenance(server_path: Path, tui_path: Path) -> dict[str, object] | None:
    manifest = server_path.parent / "build.json"
    try:
        build = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(build, dict):
        return None
    fields = (
        "source_commit",
        "v_compiler_commit",
        "v_compiler_version",
        "c_compiler",
        "c_compiler_version",
        "build_flags",
        "target",
        "binary_sha256",
        "tui_binary_sha256",
        "tui_build_target",
        "tui_bun_version",
        "runner",
    )
    provenance = {field: build[field] for field in fields if field in build}
    checks = (
        ("binary_sha256", server_path),
        ("tui_binary_sha256", tui_path),
    )
    expected = [(build[field], path) for field, path in checks if isinstance(build.get(field), str)]
    provenance["binary_hashes_match"] = len(expected) == len(checks) and all(
        actual == sha256_file(path) for actual, path in expected
    )
    return provenance


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", required=True, type=Path)
    parser.add_argument("--tui", required=True, type=Path)
    parser.add_argument("--startup-samples", type=int, default=1)
    parser.add_argument("--metrics-output", type=Path)
    args = parser.parse_args()
    if not 1 <= args.startup_samples <= 10:
        parser.error("--startup-samples must be between 1 and 10")
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

        def start_server() -> subprocess.Popen[bytes]:
            process = subprocess.Popen(
                [str(server_path), "serve"],
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            wait_for_server(process, port)
            return process

        def stop_server(process: subprocess.Popen[bytes]) -> None:
            if process.poll() is not None:
                return
            if os.name == "nt":
                process.terminate()
            else:
                process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)

        try:
            server = start_server()
            samples_ms = [run_tui(tui_path, env) for _ in range(args.startup_samples)]
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
            if ("user", "Stream incrementally") not in persisted or ("assistant", "Streaming fixture reply arrives in two pieces") not in persisted:
                raise RuntimeError(f"TUI conversation was not persisted correctly: {messages!r}")
            # Restart the backend on the same data directory: the session
            # must reopen with its transcript intact and recovery must not
            # replay or duplicate any persisted message.
            before_restart = [(message.get("role"), message.get("content")) for message in messages]
            stop_server(server)
            server = start_server()
            run_tui(tui_path, env, session_title, session_id, recovery_only=True)
            with urlopen(f"http://127.0.0.1:{port}/v1/sessions/{session_id}/messages", timeout=5) as response:
                after_messages = json.load(response)
            after_restart = [(message.get("role"), message.get("content")) for message in after_messages]
            if after_restart != before_restart:
                raise RuntimeError(
                    "backend restart changed the persisted conversation: "
                    f"before={before_restart!r}, after={after_restart!r}"
                )
            restart_coverage = {
                "journey": "conversation persisted -> backend SIGINT/terminate -> restart on same data dir -> TUI reopen -> transcript + ready composer, no new prompt sent",
                "messagesBeforeRestart": len(before_restart),
                "messagesAfterRestart": len(after_restart),
                "messagesUnchanged": after_restart == before_restart,
            }
            review_session_id, review_edit_id, review_workspace, expected_content = create_review_fixture(
                port,
                Path(temporary),
            )
            run_tui(tui_path, env, review_path=b"review.txt")
            review_state = api_json(
                port,
                "GET",
                f"/v1/sessions/{quote(review_session_id, safe='')}/workspace/edits/{quote(review_edit_id, safe='')}",
            )
            actual_content = (review_workspace / "review.txt").read_text(encoding="utf-8")
            if review_state.get("status") != "applied" or actual_content != expected_content:
                raise RuntimeError(
                    "TUI approval did not apply the pending workspace edit: "
                    f"status={review_state.get('status')!r}, content={actual_content!r}"
                )
            review_coverage = {
                "journey": "connected home -> seeded session -> Ctrl+R review -> approve workspace edit -> session composer",
                "workspaceEditStatus": review_state["status"],
                "fileContentVerified": actual_content == expected_content,
            }
        finally:
            if server is not None:
                stop_server(server)
            if provider.poll() is None:
                provider.terminate()
            try:
                provider.wait(timeout=5)
            except subprocess.TimeoutExpired:
                provider.kill()
                provider.wait(timeout=5)

    ordered = sorted(samples_ms)
    provenance = read_build_provenance(server_path, tui_path)
    build_commit = provenance.get("source_commit") if provenance and provenance.get("binary_hashes_match") else None
    metrics = {
        "schema": "veasel.tui-startup.v1",
        "measuredAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "commit": build_commit or os.environ.get("GITHUB_SHA"),
        "workflowCommit": os.environ.get("GITHUB_SHA"),
        "host": {
            "os": platform.system(),
            "release": platform.release(),
            "architecture": platform.machine(),
            "cpuCount": os.cpu_count(),
        },
        "binaries": {"server": server_path.name, "tui": tui_path.name},
        "buildProvenance": provenance,
        "measurement": "TUI process launch to connected home markers (connected, SESSIONS, VEASEL); local backend already healthy; one full keyboard smoke journey per sample",
        "interactiveCoverage": review_coverage,
        "restartCoverage": restart_coverage,
        "startupMs": {
            "samples": samples_ms,
            "count": len(samples_ms),
            "min": min(ordered),
            "median": statistics.median(ordered),
            "max": max(ordered),
        },
        "exclusions": "Not render FPS, model/token latency, coding-task quality, or a cross-runner performance guarantee.",
    }
    if args.metrics_output:
        args.metrics_output.parent.mkdir(parents=True, exist_ok=True)
        args.metrics_output.write_text(json.dumps(metrics, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(metrics, indent=2))
    print("Standalone TUI completed a mock-provider conversation through the isolated backend.")


if __name__ == "__main__":
    main()
