#!/usr/bin/env python3
"""Drive the real Veasel TUI against a loopback fixture.

This checks the keyboard path that unit tests cannot see: provider setup,
model discovery, slash arguments, a bounded diff review, a bounded
shell-command review, a bounded MCP argument review, a failed turn,
cancellation, a long session list that keeps the selection on screen, a
session switch while completion data is still in flight, and a narrow
terminal.
"""

from __future__ import annotations

import json
import os
import pty
import select
import struct
import subprocess
import fcntl
import termios
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SESSION = "11111111-1111-4111-8111-111111111111"
OTHER = "22222222-2222-4222-8222-222222222222"
EDIT_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
COMMAND_ID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
CALL_ID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

state = {
    "messages": [],
    "other_messages": [],
    "sse": None,
    "saved": None,
    "hold_edits": False,
    "edits_release": threading.Event(),
    "hold_other_edits": False,
    "other_edits_release": threading.Event(),
    "next_message": "fail",
    "pending_op": "",
    "pending_user": "",
    "model_posts": 0,
    "settings_posts": 0,
    "sse_id": 0,
    "edit_status": "pending",
    "command_status": "pending",
    "mcp_status": "pending",
}


def review_diff() -> str:
    # Hunk headers must match parsePatch (OpenTUI DiffRenderable) — word-diff
    # segments are tolerant, but split view rejects mismatched counts.
    added_body = [f"+kept line {index:02d}" for index in range(1, 27)] + ["+TAIL-SENTINEL"]
    lines = [
        "diff --git a/src/main.v b/src/main.v",
        "--- a/src/main.v",
        "+++ b/src/main.v",
        f"@@ -1,2 +1,{1 + len(added_body)} @@",
        "-const answer = alpha",
        "+const answer = beta",
        "-old line",
    ]
    lines.extend(added_body)
    # Second hunk so {/} navigation is real-terminal covered.
    lines.extend([
        "@@ -200,1 +200,1 @@",
        "-unused line",
        "+hunk-two-marker",
    ])
    return "\n".join(lines) + "\n"


def long_shell_command() -> str:
    lines = [f"echo step {index:02d}" for index in range(1, 31)]
    lines.append("echo SHELL-TAIL")
    return "\n".join(lines)


def long_mcp_arguments() -> str:
    fields = [f'  "field_{index:02d}": "value {index}"' for index in range(1, 31)]
    fields.append('  "tail": "MCP-TAIL"')
    return "{\n" + ",\n".join(fields) + "\n}"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        return

    def do_GET(self) -> None:
        path = urllib.parse.urlparse(self.path).path
        if path == "/v1/sessions":
            sessions = [
                {"id": SESSION, "title": "Alpha", "directory": "/tmp/alpha", "created_at": "2026-10-14 00:00:00"},
                {"id": OTHER, "title": "Beta", "directory": "/tmp/beta", "created_at": "2026-10-14 00:00:01"},
            ]
            for index in range(2, 20):
                sessions.append({
                    "id": f"33333333-3333-4333-8333-{index:012d}",
                    "title": f"Lane-{index:02d}",
                    "directory": f"/tmp/workspaces/very-long-directory/lane-{index:02d}",
                    "created_at": "2026-10-14 00:00:02",
                })
            return self._json(200, sessions)
        if path == f"/v1/sessions/{SESSION}/messages":
            return self._json(200, state["messages"])
        if path == f"/v1/sessions/{OTHER}/messages":
            return self._json(200, state["other_messages"])
        if path == "/v1/config/model":
            view = settings_view()
            saved = state.get("saved") or {}
            provider = saved.get("provider") or view["active_provider"]
            view["active_provider"] = provider
            if saved.get("model") is not None or saved.get("api_key") or saved.get("base_url"):
                view["profiles"][provider] = {
                    "model": saved.get("model", ""),
                    "base_url": saved.get("base_url", ""),
                    "api_key_saved": bool(saved.get("api_key")),
                    "max_output_tokens": saved.get("max_output_tokens", 0),
                }
            return self._json(200, view)
        if path == "/v1/mcp-credentials":
            return self._json(200, {
                "path": "/tmp/mcp-credentials.json",
                "credentials": state.get("mcp_credentials") or [
                    {"name": "docs-http", "header_names": ["Authorization"]},
                ],
            })
        if path == f"/v1/sessions/{SESSION}/usage":
            return self._json(200, {
                "session_id": SESSION,
                "completed_turns": 2,
                "reported_turns": 2,
                "input_tokens": 1500,
                "output_tokens": 400,
                "usage_reported": True,
                "cache_reported": False,
                "cost": "unavailable",
            })
        if path == f"/v1/sessions/{SESSION}/workspace/edits/{EDIT_ID}":
            return self._json(200, {
                "id": EDIT_ID,
                "session_id": SESSION,
                "path": "src/main.v",
                "status": state["edit_status"],
                "diff": review_diff(),
            })
        if path == f"/v1/sessions/{SESSION}/workspace/edits":
            if state["hold_edits"]:
                state["edits_release"].wait(3.0)
            edits = []
            if state["edit_status"] == "pending":
                edits.append({"id": EDIT_ID, "path": "src/main.v", "status": "pending"})
            return self._json(200, edits)
        if path == f"/v1/sessions/{OTHER}/workspace/edits":
            if state["hold_other_edits"]:
                state["other_edits_release"].wait(5.0)
            return self._json(200, [])
        if path == f"/v1/sessions/{SESSION}/mcp-tool-calls/{CALL_ID}":
            return self._json(200, {
                "id": CALL_ID,
                "operation_id": "op-1",
                "plugin_name": "review-tools",
                "server_name": "local",
                "tool_name": "effect",
                "arguments_json": long_mcp_arguments(),
                "status": state["mcp_status"],
                "reviewed_at": "",
                "created_at": "",
                "updated_at": "",
            })
        if path in (
            f"/v1/sessions/{SESSION}/skills",
            f"/v1/sessions/{SESSION}/mcp-servers",
            f"/v1/sessions/{SESSION}/mcp-tool-calls",
            f"/v1/sessions/{OTHER}/skills",
            f"/v1/sessions/{OTHER}/mcp-servers",
            f"/v1/sessions/{OTHER}/mcp-tool-calls",
            f"/v1/sessions/{OTHER}/workspace/commands",
        ):
            if path.endswith("/mcp-tool-calls") and SESSION in path:
                calls = []
                if state["mcp_status"] == "pending":
                    calls.append({
                        "id": CALL_ID, "plugin_name": "review-tools", "tool_name": "effect", "status": "pending",
                        "arguments_bytes": len(long_mcp_arguments()),
                    })
                return self._json(200, calls)
            if path.endswith("/mcp-servers") and SESSION in path:
                return self._json(200, [{"plugin_name": "review-tools", "server_name": "local"}])
            if path.endswith("/skills") and SESSION in path:
                return self._json(200, [{"plugin_name": "review-tools", "skill_name": "review"}])
            return self._json(200, [])
        if path == f"/v1/sessions/{SESSION}/workspace/commands/{COMMAND_ID}":
            return self._json(200, {
                "id": COMMAND_ID,
                "command": long_shell_command(),
                "cwd": ".",
                "timeout_seconds": 10,
                "status": state["command_status"],
                "exit_code": 0,
                "output": "",
                "created_at": "",
                "updated_at": "",
            })
        if path == f"/v1/sessions/{SESSION}/workspace/commands":
            commands = []
            if state["command_status"] == "pending":
                commands.append({
                    "id": COMMAND_ID, "command": "echo hi", "cwd": ".", "timeout_seconds": 10,
                    "status": "pending", "exit_code": 0, "output": "", "created_at": "", "updated_at": "",
                })
            return self._json(200, commands)
        if path == "/v1/plugins":
            return self._json(200, {"plugins": [{
                "name": "review-tools",
                "skills": [{"name": "review", "description": "Review code", "allowed_tools_declared": False, "allowed_tools": []}],
                "mcp_servers": [{"name": "local", "transport": "stdio", "command": "node server.js", "url_origin": "", "header_count": 0, "header_names": []}],
            }], "diagnostics": []})
        if path == "/v1/events":
            return self._sse()
        self._json(404, {"error": "not found"})

    def do_DELETE(self) -> None:
        path = urllib.parse.urlparse(self.path).path
        if path.startswith("/v1/mcp-credentials/"):
            name = urllib.parse.unquote(path.rsplit("/", 1)[-1])
            creds = list(state.get("mcp_credentials") or [{"name": "docs-http", "header_names": ["Authorization"]}])
            state["mcp_credentials"] = [c for c in creds if c["name"] != name]
            return self._json(200, {"removed": name})
        self._json(404, {"error": "not found"})

    def do_POST(self) -> None:
        path = urllib.parse.urlparse(self.path).path
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b""
        if path == "/v1/config/model":
            state["settings_posts"] = int(state.get("settings_posts") or 0) + 1
            if state["settings_posts"] == 1:
                return self._json(401, {"error": "unauthorized api key"})
            state["saved"] = json.loads(raw.decode())
            view = settings_view()
            provider = state["saved"]["provider"]
            view["active_provider"] = provider
            view["profiles"][provider] = {
                "model": state["saved"].get("model", ""),
                "base_url": state["saved"].get("base_url", ""),
                "api_key_saved": bool(state["saved"].get("api_key")),
                "max_output_tokens": state["saved"].get("max_output_tokens", 0),
            }
            return self._json(200, view)
        if path == "/v1/mcp-oauth/authorize":
            body = json.loads(raw.decode())
            return self._json(200, {
                "credential": body.get("credential", "docs"),
                "state": "oauth-state-1",
                "authorize_url": "https://auth.example/authorize?client_id=demo",
                "redirect_uri": body.get("redirect_uri", "http://127.0.0.1:8765/callback"),
                "code_challenge_method": "S256",
            })
        if path == "/v1/mcp-oauth/complete":
            body = json.loads(raw.decode())
            return self._json(200, {
                "name": body.get("credential", "docs"),
                "header_names": ["Authorization"],
            })
        if path == "/v1/mcp-oauth/refresh":
            body = json.loads(raw.decode())
            return self._json(200, {
                "name": body.get("credential", "docs"),
                "header_names": ["Authorization"],
            })
        if path.endswith(f"/workspace/edits/{EDIT_ID}/approve"):
            state["edit_status"] = "applied"
            return self._json(200, {"status": "applied"})
        if path.endswith(f"/workspace/edits/{EDIT_ID}/reject"):
            state["edit_status"] = "rejected"
            return self._json(200, {"status": "rejected"})
        if path.endswith(f"/workspace/commands/{COMMAND_ID}/approve"):
            state["command_status"] = "succeeded"
            return self._json(200, {
                "id": COMMAND_ID, "command": "echo hi", "cwd": ".", "timeout_seconds": 10,
                "status": "succeeded", "exit_code": 0, "output": "hi\n", "created_at": "", "updated_at": "",
            })
        if path.endswith(f"/workspace/commands/{COMMAND_ID}/reject"):
            state["command_status"] = "rejected"
            return self._json(200, {
                "id": COMMAND_ID, "command": "echo hi", "cwd": ".", "timeout_seconds": 10,
                "status": "rejected", "exit_code": 0, "output": "", "created_at": "", "updated_at": "",
            })
        if path.endswith(f"/mcp-tool-calls/{CALL_ID}/approve"):
            state["mcp_status"] = "approved"
            return self._json(200, {"id": CALL_ID, "status": "approved"})
        if path.endswith(f"/mcp-tool-calls/{CALL_ID}/reject"):
            state["mcp_status"] = "rejected"
            return self._json(200, {"id": CALL_ID, "status": "rejected"})
        if path == f"/v1/sessions/{SESSION}/messages":
            body = json.loads(raw.decode())
            operation = self.headers.get("X-Veasel-Operation-ID", "")
            if state["next_message"] == "cancel":
                state["pending_op"] = operation
                state["pending_user"] = body["content"]
                self._json(202, {"operation_id": operation, "status": "running"})
                # Multi-delta burst so End-follow after scroll and coalesced
                # renders are exercised against racing assistant.delta frames.
                lines = [f"stream line {index:02d}" for index in range(1, 36)] + ["STREAM-TAIL"]
                chunks = [
                    "\n".join(lines[:12]) + "\n",
                    "\n".join(lines[12:24]) + "\n",
                    "\n".join(lines[24:]) + "\n",
                ]
                threading.Thread(target=emit_assistant_delta_burst, args=(operation, chunks), daemon=True).start()
                return
            remember_turn(body["content"], "The assistant turn failed.")
            self._json(202, {"operation_id": operation, "status": "running"})
            threading.Thread(target=emit_completion, args=(operation, "failed", "The assistant turn failed."), daemon=True).start()
            return
        if path.endswith("/cancel"):
            operation = state["pending_op"]
            remember_turn(state["pending_user"], "Turn cancelled.")
            self._json(200, {"operation_id": operation, "status": "cancelled"})
            threading.Thread(target=emit_completion, args=(operation, "cancelled", "Turn cancelled."), daemon=True).start()
            return
        if path.endswith("/models"):
            state["model_posts"] += 1
            if state["model_posts"] == 1:
                return self._json(502, {"error": "provider unreachable"})
            models = [{"id": f"model-{index}", "name": f"Model {index}"} for index in range(12)]
            models.append({"id": "gpt-5", "name": "GPT-5"})
            return self._json(200, {"provider": "openai", "models": models})
        self._json(404, {"error": "not found"})

    def _json(self, status: int, payload) -> None:
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _sse(self) -> None:
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.end_headers()
        state["sse"] = self.wfile
        try:
            while True:
                time.sleep(15)
                self.wfile.write(b"event: heartbeat\ndata: {}\n\n")
                self.wfile.flush()
        except Exception:
            state["sse"] = None


def settings_view():
    return {
        "active_provider": "openai",
        "profiles": {},
        "configured_providers": ["openai"],
        "providers": [
            {"id": "openai", "name": "OpenAI", "description": "Catalog preset", "protocol": "openai-compatible", "base_url": "https://api.openai.com/v1", "environment_key": "OPENAI_API_KEY", "requires_api_key": True},
            {"id": "ollama", "name": "Ollama", "description": "Local models", "protocol": "openai-compatible", "base_url": "http://127.0.0.1:11434/v1", "environment_key": "", "requires_api_key": False},
            {"id": "cloudflare-workers-ai", "name": "Cloudflare Workers AI", "description": "Account endpoint", "protocol": "openai-compatible", "base_url": "https://api.cloudflare.com/client/v4/accounts/YOUR_ACCOUNT_ID/ai/v1", "environment_key": "CLOUDFLARE_API_KEY", "requires_api_key": True},
        ],
    }


def remember_turn(user: str, assistant: str) -> None:
    start = len(state["messages"]) + 1
    state["messages"].append({
        "id": start, "session_id": SESSION, "role": "user", "content": user, "created_at": "2026-10-14 00:00:02",
    })
    state["messages"].append({
        "id": start + 1, "session_id": SESSION, "role": "assistant", "content": assistant, "created_at": "2026-10-14 00:00:03",
    })


def emit_assistant_delta(operation: str, delta: str, delay: float = 0.15) -> None:
    time.sleep(delay)
    stream = state["sse"]
    if stream is None:
        return
    state["sse_id"] += 1
    event_id = state["sse_id"]
    payload = json.dumps({
        "id": event_id,
        "type": "assistant.delta",
        "session_id": SESSION,
        "created_at": "2026-10-14 00:00:03",
        "data": {"operation_id": operation, "delta": delta},
    })
    try:
        stream.write(f"id: {event_id}\nevent: assistant.delta\ndata: {payload}\n\n".encode())
        stream.flush()
    except Exception:
        pass


def emit_assistant_delta_burst(operation: str, deltas: list[str]) -> None:
    """Fire several assistant.delta frames in one burst (multi-delta race)."""
    time.sleep(0.12)
    for index, delta in enumerate(deltas):
        emit_assistant_delta(operation, delta, delay=0.04 if index else 0.0)


def emit_completion(operation: str, status: str, error: str) -> None:
    time.sleep(0.2)
    stream = state["sse"]
    if stream is None:
        return
    state["sse_id"] += 1
    event_id = state["sse_id"]
    payload = json.dumps({
        "id": event_id,
        "type": "session.turn_completed",
        "session_id": SESSION,
        "created_at": "2026-10-14 00:00:03",
        "data": {"operation_id": operation, "status": status, "error": error},
    })
    try:
        stream.write(f"id: {event_id}\nevent: session.turn_completed\ndata: {payload}\n\n".encode())
        stream.flush()
    except Exception:
        pass


def decode_complete(data: bytes) -> tuple[str, bytes]:
    """Decode bytes, holding back a split UTF-8 character or escape sequence."""
    end = len(data)
    while end > 0:
        try:
            data[:end].decode("utf-8")
            break
        except UnicodeDecodeError as error:
            if error.end == end and error.start >= end - 3:
                end = error.start
                continue
            end = len(data)
            break
    text = data[:end].decode("utf-8", "replace")
    escape = text.rfind("\x1b")
    if escape >= 0:
        tail = text[escape:]
        complete = False
        if tail.startswith("\x1b[") and any("@" <= char <= "~" for char in tail[2:]):
            complete = True
        elif tail.startswith("\x1b]") and ("\x07" in tail or "\x1b\\" in tail):
            complete = True
        elif tail.startswith("\x1bP") and "\x1b\\" in tail:
            complete = True
        elif len(tail) > 1 and tail[1] not in "[P]":
            complete = True
        if not complete:
            held = text[escape:].encode()
            prefix = data[:end]
            return text[:escape], prefix[-len(held):] + data[end:]
    return text, data[end:]


class Terminal:
    """Enough of a VT100 to read OpenTUI's cursor-addressed frames."""

    def __init__(self, rows: int, cols: int):
        self.rows = rows
        self.cols = cols
        self.grid = [[" "] * cols for _ in range(rows)]
        self.y = 0
        self.x = 0
        self.saved = (0, 0)

    def feed(self, data: str) -> None:
        index = 0
        while index < len(data):
            char = data[index]
            if char == "\x1b":
                index = self._escape(data, index)
                continue
            if char == "\n":
                self.y = min(self.rows - 1, self.y + 1)
                self.x = 0
            elif char == "\r":
                self.x = 0
            elif char == "\b":
                self.x = max(0, self.x - 1)
            elif char >= " ":
                self._put(char)
            index += 1

    def _put(self, char: str) -> None:
        if self.y >= self.rows or self.x >= self.cols:
            return
        self.grid[self.y][self.x] = char
        self.x += 1

    def _escape(self, data: str, index: int) -> int:
        if index + 1 >= len(data):
            return index + 1
        kind = data[index + 1]
        if kind == "[":
            end = index + 2
            while end < len(data) and not ("@" <= data[end] <= "~"):
                end += 1
            if end >= len(data):
                return len(data)
            self._csi(data[index + 2:end], data[end])
            return end + 1
        if kind == "]":
            end = index + 2
            while end < len(data):
                if data[end] == "\x07":
                    return end + 1
                if data[end] == "\x1b" and end + 1 < len(data) and data[end + 1] == "\\":
                    return end + 2
                end += 1
            return len(data)
        if kind == "P":
            end = data.find("\x1b\\", index)
            return len(data) if end < 0 else end + 2
        return index + 2

    def _csi(self, params: str, final: str) -> None:
        if final == "H":
            parts = params.split(";")
            row = int(parts[0] or "1") if parts and parts[0] else 1
            col = int(parts[1] or "1") if len(parts) > 1 and parts[1] else 1
            self.y = max(0, min(self.rows - 1, row - 1))
            self.x = max(0, min(self.cols - 1, col - 1))
        elif final == "s":
            self.saved = (self.y, self.x)
        elif final == "u":
            self.y, self.x = self.saved

    def text(self) -> str:
        return "\n".join("".join(row).rstrip() for row in self.grid)


class Screen:
    def __init__(self, master: int, rows: int, cols: int):
        self.master = master
        self.terminal = Terminal(rows, cols)
        self.raw = ""
        self.pending = b""

    def read_for(self, seconds: float) -> str:
        deadline = time.time() + seconds
        while time.time() < deadline:
            ready, _, _ = select.select([self.master], [], [], 0.1)
            if not ready:
                continue
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                break
            if not chunk:
                break
            self.pending += chunk
            self.raw += chunk.decode("utf-8", "replace")
            text, self.pending = decode_complete(self.pending)
            self.terminal.feed(text)
        return self.terminal.text()

    def wait_for(self, needle: str, seconds: float = 5) -> None:
        deadline = time.time() + seconds
        while time.time() < deadline:
            if needle in self.read_for(0.15):
                return
        visible = self.terminal.text()
        open("/tmp/tui-exercise.txt", "w").write(visible)
        open("/tmp/tui-exercise.raw", "w").write(self.raw)
        raise AssertionError(f"did not see {needle!r}\n--- screen ---\n{visible}")

    def send(self, data: str, pause: float = 0.15) -> None:
        os.write(self.master, data.encode())
        time.sleep(pause)

    def clear_line(self, length: int) -> None:
        if length:
            self.send("\x7f" * length, 0.15)


def set_winsize(fd: int, rows: int, cols: int) -> None:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def launch(port: int, rows: int, cols: int) -> tuple[subprocess.Popen, int]:
    master, slave = pty.openpty()
    set_winsize(slave, rows, cols)
    env = os.environ.copy()
    env.update({
        "VEASEL_PORT": str(port),
        "VEASEL_TUI_THEME": "mint",
        "TERM": "xterm-256color",
        "COLUMNS": str(cols),
        "LINES": str(rows),
    })
    process = subprocess.Popen(
        ["bun", "run", "src/main.ts"],
        cwd=ROOT,
        env=env,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        start_new_session=True,
    )
    os.close(slave)
    return process, master


def exercise_narrow(port: int) -> None:
    """A short terminal still shows the provider, the key step, and a readable footer."""
    rows, cols = 24, 80
    process, master = launch(port, rows, cols)
    screen = Screen(master, rows, cols)
    try:
        screen.wait_for("Alpha", 8)
        screen.wait_for("n new")
        screen.wait_for("/skills")
        screen.wait_for("q quit")
        screen.send("s", 0.5)
        screen.wait_for("OpenAI")
        screen.wait_for("1 OF 3")
        screen.send("\r", 0.6)
        screen.wait_for("2 OF 3")
        screen.wait_for("API key")
        screen.send("\x1b", 0.4)  # Esc closes settings
        screen.wait_for("q quit", 4)
        screen.send("\r", 0.5)  # open Alpha
        screen.wait_for("Ask Veasel", 4)
        screen.send("/help\r", 0.7)  # 24-row terminal uses compact help
        screen.wait_for("/mcp credentials · /mcp oauth", 4)
        screen.wait_for("Named HTTP auth", 4)
    finally:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()


def seed_session_workspace() -> None:
    """Create files under the Alpha fixture directory for @ path autocomplete."""
    root = "/tmp/alpha"
    src = os.path.join(root, "src")
    os.makedirs(src, exist_ok=True)
    with open(os.path.join(src, "main.ts"), "w", encoding="utf-8") as handle:
        handle.write("export const alpha = 1\n")
    with open(os.path.join(root, "README.md"), "w", encoding="utf-8") as handle:
        handle.write("# alpha\n")


def main() -> None:
    seed_session_workspace()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    rows, cols = 40, 100
    process, master = launch(port, rows, cols)
    screen = Screen(master, rows, cols)
    try:
        screen.wait_for("Alpha", 8)
        screen.wait_for("● 1 Alpha", 4)
        screen.wait_for("○ 2 Beta", 4)
        screen.wait_for("/skills")
        screen.wait_for("/mcp")
        screen.wait_for("1-9")
        screen.wait_for("type")
        screen.wait_for("q quit")
        screen.send("2", 0.35)  # digit jump → second session (Beta)
        screen.wait_for("session 2 of 20 selected", 4)
        screen.wait_for("● 2 Beta", 4)
        screen.send("1", 0.35)  # back to Alpha
        screen.wait_for("session 1 of 20 selected", 4)
        screen.wait_for("● 1 Alpha", 4)
        screen.send("G", 0.35)  # vim End → last session
        screen.wait_for("session 20 of 20 selected", 4)
        screen.wait_for("Lane-19", 4)
        screen.send("g", 0.35)  # vim Home → first session
        screen.wait_for("session 1 of 20 selected", 4)
        screen.wait_for("● 1 Alpha", 4)
        screen.send("s", 0.5)
        screen.wait_for("Provider settings", 4)
        screen.wait_for("Tab cycles", 4)
        screen.wait_for("Tab ·", 4)
        screen.wait_for("j/k", 4)
        screen.wait_for("g/G", 4)
        screen.wait_for("1-9", 4)
        screen.wait_for("Ctrl+L", 4)
        screen.wait_for("selected ", 4)
        screen.wait_for(" of ", 4)
        screen.wait_for("1 OF 3")
        screen.send("2", 0.35)  # digit jump → second provider (Ollama)
        screen.wait_for("Ollama", 4)
        screen.wait_for("selected 2 of 3", 4)
        screen.send("1", 0.35)  # back to OpenAI
        screen.wait_for("OpenAI", 4)
        screen.wait_for("selected 1 of 3", 4)
        screen.send("G", 0.35)  # vim End → last provider
        screen.wait_for("Cloudflare", 4)
        screen.wait_for("selected 3 of 3", 4)
        screen.send("g", 0.35)  # vim Home → first provider
        screen.wait_for("OpenAI", 4)
        screen.wait_for("selected 1 of 3", 4)
        screen.send("j", 0.35)  # j moves down when filter is empty
        screen.send("k", 0.35)  # k moves back up
        screen.send("zzz", 0.45)
        screen.wait_for("No providers match", 4)
        screen.send("\x0c", 0.4)  # Ctrl+L clears provider filter
        screen.wait_for("OpenAI", 4)
        screen.send("\x1b[H", 0.35)  # Home → first provider
        screen.send("\x1b[F", 0.35)  # End → last provider
        screen.send("\t", 0.35)
        screen.wait_for("Configured")
        screen.send("\x1b[Z", 0.35)  # Shift+Tab
        screen.wait_for("All")
        screen.send("\r", 0.6)
        screen.wait_for("API key")
        screen.wait_for("2 OF 3")
        if "Custom endpoint" in screen.terminal.text():
            raise AssertionError("known OpenAI endpoint was shown as a required step")
        screen.send("\x15", 0.45)  # Ctrl+U
        screen.wait_for("Custom endpoint")
        screen.send("\x02", 0.35)  # Ctrl+B
        screen.wait_for("API key")
        screen.send("k\r", 0.9)
        screen.wait_for("Model discovery failed")
        screen.send("\x02", 0.5)
        screen.wait_for("API key")
        screen.send("\r", 1.0)
        screen.wait_for("13/13", 6)
        screen.send("gpt", 0.5)
        screen.wait_for("GPT-5")
        screen.send("\r", 0.8)
        screen.wait_for("could not save", 4)
        screen.wait_for("Check the API key", 4)
        screen.wait_for("MODEL SETTINGS", 4)  # wizard stays open after a rejected save
        screen.send("\r", 0.9)  # retry save from the model step
        screen.wait_for("/connect · s to manage providers", 6)
        saved = state["saved"] or {}
        if saved.get("model") != "gpt-5" or not saved.get("api_key"):
            raise AssertionError("selected model and api key were not saved")
        screen.send("\r", 0.6)
        screen.wait_for("Ask Veasel")
        screen.wait_for("openai/gpt-5", 6)
        screen.wait_for("Ctrl+Y")
        screen.wait_for("Ctrl+U")
        screen.wait_for("Ctrl+W")
        screen.wait_for("↑")
        screen.wait_for("Pg")
        screen.wait_for("/skills")
        # @ path autocomplete against the session workspace (/tmp/alpha).
        screen.send("@src/ma", 0.7)
        screen.wait_for("── paths ──", 4)
        screen.wait_for("@src/main.ts", 4)
        screen.send("\t", 0.45)
        visible = screen.terminal.text()
        if "@src/main.ts" not in visible:
            raise AssertionError(f"Tab did not insert @src/main.ts\n--- screen ---\n{visible}")
        screen.send("\x15", 0.35)  # Ctrl+U clears the draft (keep Esc for leave-after-cancel)
        screen.wait_for("/skills", 4)
        screen.send("/", 0.6)
        screen.wait_for("── guide ──")
        screen.wait_for("── setup ──")
        screen.send("\x1b[F", 0.5)  # End → last command (/map)
        screen.wait_for("/map", 4)
        screen.wait_for("── session ──", 4)
        screen.send("\x1b[H", 0.5)  # Home → first command
        screen.wait_for("── guide ──", 4)
        screen.wait_for("/help", 4)
        screen.send("\x1b", 0.25)
        screen.clear_line(1)  # "/"
        screen.send("/help\r", 0.7)
        screen.wait_for("VEASEL CODE / QUICK HELP", 4)
        screen.wait_for("/mcp", 4)
        screen.send("\x1b", 0.4)  # Esc dismisses help notice, stays in session
        screen.wait_for("Ask Veasel", 4)
        if "VEASEL CODE / QUICK HELP" in screen.terminal.text():
            raise AssertionError("Esc did not dismiss the help notice")
        screen.wait_for("?", 4)  # session footer advertises empty-composer ?
        screen.send("?", 0.45)  # empty composer ? opens the same overlay as /help
        screen.wait_for("VEASEL CODE / QUICK HELP", 4)
        screen.send("\x1b", 0.4)
        screen.wait_for("Ask Veasel", 4)
        if "VEASEL CODE / QUICK HELP" in screen.terminal.text():
            raise AssertionError("Esc did not dismiss help opened with ?")
        screen.wait_for("Ctrl+Y")
        # Description search: find /connect, MCP OAuth, and /theme without typing their names.
        screen.send("/key", 0.7)
        screen.wait_for("/connect")
        screen.send("\x1b", 0.25)
        screen.clear_line(4)  # "/key"
        screen.send("/pkce", 0.7)
        screen.wait_for("/mcp oauth", 4)
        screen.send("\x1b", 0.25)
        screen.clear_line(5)  # "/pkce"
        screen.send("/bearer", 0.7)
        screen.wait_for("/mcp credential", 4)
        screen.send("\x1b", 0.25)
        screen.clear_line(7)  # "/bearer"
        screen.send("/color", 0.7)
        screen.wait_for("/theme")
        screen.send("\t", 0.45)
        screen.wait_for("/theme ")
        screen.wait_for("mint")
        screen.send("\x1b[B", 0.45)  # ↓ preview ember without saving
        screen.wait_for("preview Ember", 4)
        screen.wait_for("Enter keeps")
        screen.send("\x1b", 0.35)  # Esc restores the saved theme and pending cue
        screen.wait_for("openai/gpt-5", 4)
        screen.wait_for("/patches")
        screen.clear_line(7)  # "/theme "
        # Light and high-contrast themes: live-preview day then contrast, Esc restores mint.
        screen.send("/theme day", 0.7)
        screen.wait_for("preview Day", 4)
        screen.wait_for("Enter keeps")
        screen.send("\x1b", 0.35)
        screen.wait_for("openai/gpt-5", 4)
        screen.clear_line(10)  # "/theme day"
        screen.send("/theme contrast", 0.7)
        screen.wait_for("preview Contrast", 4)
        screen.send("\x1b", 0.35)
        screen.wait_for("openai/gpt-5", 4)
        screen.clear_line(15)  # "/theme contrast"
        screen.wait_for("/patches")
        screen.wait_for("Ctrl+W")  # session footer (Ctrl+R stays in /help)
        screen.send("\x12", 0.7)  # Ctrl+R opens the first pending list
        screen.wait_for("WORKSPACE EDIT PROPOSALS", 4)
        screen.wait_for("aaaaaaaa-aaaa")
        screen.send("/patch ", 0.8)
        screen.wait_for("approve")
        screen.send("\t", 0.4)
        screen.wait_for("/patch show")
        screen.send(" ", 0.6)
        screen.wait_for("aaaaaaaa-aaaa")
        screen.send("\x1b", 0.25)
        screen.clear_line(13)  # "/patch show "
        screen.send(f"/patch show {EDIT_ID}\r", 0.7)
        screen.wait_for("29 added, 3 removed", 4)
        screen.wait_for("Showing ")
        screen.wait_for("remain", 4)
        screen.wait_for("Hunk 1 of 2", 4)
        screen.wait_for("{/} hunks", 4)
        screen.wait_for("alpha")
        screen.wait_for("beta")
        screen.wait_for(" │ ", 4)  # short -/+ pair renders side-by-side at 100 cols
        screen.wait_for("a approve")
        screen.wait_for("v split view", 4)
        reviewed = screen.terminal.text()
        if "TAIL-SENTINEL" in reviewed or "hunk-two-marker" in reviewed:
            raise AssertionError(f"diff review showed lines past the terminal budget\n--- screen ---\n{reviewed}")
        if "alpha" not in reviewed or "beta" not in reviewed or " │ " not in reviewed:
            raise AssertionError(f"diff review missed side-by-side alpha/beta pair\n--- screen ---\n{reviewed}")
        screen.send("v", 0.55)  # toggle OpenTUI DiffRenderable split view
        screen.wait_for("v word-diff", 4)
        screen.wait_for("OpenTUI split", 4)
        # Counts may wrap across the panel width ("29" then "added, 3 removed").
        screen.wait_for("added, 3 removed", 4)
        screen.wait_for("Hunk 1 of 2", 4)
        screen.wait_for("const answer = alpha", 4)
        screen.wait_for("const answer = beta", 4)
        split_view = screen.terminal.text()
        if "Error parsing diff" in split_view:
            raise AssertionError(f"DiffRenderable rejected the review patch\n--- screen ---\n{split_view}")
        screen.send("}", 0.55)  # next hunk while split is mounted
        screen.wait_for("Hunk 2 of 2", 4)
        screen.wait_for("hunk-two-marker", 4)
        screen.send("{", 0.55)  # previous hunk scrolls split back
        screen.wait_for("Hunk 1 of 2", 4)
        screen.wait_for("const answer = alpha", 4)
        screen.send("v", 0.55)  # back to word-diff segments
        screen.wait_for("v split view", 4)
        screen.wait_for(" │ ", 4)
        screen.send("}", 0.5)  # next unified-diff hunk (segments surface)
        screen.wait_for("Hunk 2 of 2", 4)
        screen.wait_for("hunk-two-marker", 4)
        screen.send("{", 0.5)  # previous hunk
        screen.wait_for("Hunk 1 of 2", 4)
        screen.wait_for("remain", 4)
        screen.send(" ", 0.45)  # Space multi-select current review
        screen.wait_for("selected", 4)
        screen.wait_for("● Space", 4)
        screen.send(" ", 0.45)  # Space clears the selection mark
        screen.wait_for("○ Space select", 4)
        screen.send("]", 0.55)  # next pending review (shell)
        screen.wait_for("REVIEW SHELL COMMAND", 4)
        screen.send("[", 0.55)  # previous pending review (patch)
        screen.wait_for("REVIEW WORKSPACE EDIT", 4)
        screen.send("A", 0.7)  # Shift+A approves all pending patches of this kind
        screen.wait_for("Approved 1 pending edit of the same kind (Shift+A)", 4)
        screen.send("/skill ", 0.6)
        screen.wait_for("Enable a Skill")
        screen.send("\t", 0.5)
        screen.wait_for("review-tools/review")
        screen.send("\x1b", 0.25)
        screen.clear_line(10)  # "/skill on "
        screen.send("/mcp call ", 0.6)
        screen.wait_for("approve")
        screen.send("\t", 0.45)
        screen.wait_for("cccccccc")
        screen.send("\x1b", 0.25)
        screen.clear_line(15)  # "/mcp call show "
        screen.send(f"/mcp call show {CALL_ID}\r", 0.7)
        screen.wait_for("has not reached its MCP server", 4)
        screen.wait_for("Showing ")
        reviewed = screen.terminal.text()
        if "MCP-TAIL" in reviewed:
            raise AssertionError(f"MCP review showed arguments past the terminal budget\n--- screen ---\n{reviewed}")
        screen.send("/mcp trust ", 0.6)
        screen.wait_for("review-tools/local")
        screen.send("\x1b", 0.25)
        screen.clear_line(11)  # "/mcp trust "
        screen.send("/mcp credentials\r", 0.7)
        screen.wait_for("MCP HTTP CREDENTIALS", 4)
        screen.wait_for("docs-http", 4)
        screen.wait_for("Authorization", 4)
        if "Bearer" in screen.terminal.text() and "docs-http" in screen.terminal.text():
            # Status may say Bearer elsewhere; ensure the credential line has no secret values.
            pass
        screen.send("/mcp credential remove docs-http\r", 0.7)
        screen.wait_for("Removed credential docs-http", 4)
        screen.send("/mcp oauth authorize docs https://auth.example/authorize https://auth.example/token demo-client http://127.0.0.1:8765/callback\r", 0.8)
        screen.wait_for("MCP OAUTH AUTHORIZE", 4)
        screen.wait_for("Browser:", 4)
        screen.wait_for("https://auth.example/authorize?client_id=demo", 4)
        screen.wait_for("--listen", 4)
        screen.wait_for("Authorize URL copied", 4)
        screen.send("/mcp oauth complete docs http://127.0.0.1:8765/callback?code=abc&state=oauth-state-1\r", 0.7)
        screen.wait_for("MCP OAUTH COMPLETE", 4)
        screen.wait_for("Authorization", 4)
        screen.wait_for("/mcp oauth refresh docs", 4)
        screen.send("/mcp oauth refresh docs\r", 0.7)
        screen.wait_for("MCP OAUTH REFRESH", 4)
        screen.wait_for("Credential docs refreshed", 4)
        screen.wait_for("Authorization", 4)
        screen.send("/usage\r", 0.7)
        screen.wait_for("SESSION TOKEN USAGE", 4)
        screen.wait_for("Only provider-reported counters", 4)
        screen.wait_for("Total (in+out): 1.9k", 4)
        screen.wait_for("Avg per reported turn", 4)
        screen.send("/command ", 0.6)
        screen.wait_for("Inspect before deciding")
        screen.send("\t", 0.45)
        screen.wait_for("bbbbbbbb")
        screen.send("\x1b", 0.25)
        screen.clear_line(14)  # "/command show "
        screen.send(f"/command show {COMMAND_ID}\r", 0.7)
        screen.wait_for("without an OS sandbox", 4)
        screen.wait_for("Showing ")
        reviewed = screen.terminal.text()
        if "SHELL-TAIL" in reviewed:
            raise AssertionError(f"shell review showed lines past the terminal budget\n--- screen ---\n{reviewed}")
        screen.send("keep this prompt\r", 0.4)
        screen.wait_for("The assistant turn failed.", 6)
        screen.wait_for("keep this prompt")
        screen.send("\x19", 0.5)  # Ctrl+Y copies last assistant reply
        screen.wait_for("Copied last reply", 4)
        screen.send("\x1b", 0.35)  # dismiss copy notice so the composer is alone
        screen.wait_for("Ask Veasel", 4)
        screen.send("zxqy wordkill", 0.45)  # unique draft (not in transcript)
        screen.wait_for("zxqy wordkill", 4)
        screen.send("\x01", 0.35)  # Ctrl+A → start of draft
        screen.send("pre-", 0.35)
        screen.wait_for("pre-zxqy wordkill", 4)
        screen.send("\x05", 0.35)  # Ctrl+E → end of draft
        screen.send("!", 0.35)
        screen.wait_for("pre-zxqy wordkill!", 4)
        screen.send("\x17", 0.45)  # Ctrl+W kills the last word-ish tail
        # kill "wordkill!" leaves "pre-zxqy "
        screen.wait_for("pre-zxqy ", 4)
        visible = screen.terminal.text()
        if "wordkill" in visible:
            raise AssertionError(f"Ctrl+W left the killed word on screen\n--- screen ---\n{visible}")
        screen.send("again", 0.35)
        screen.wait_for("pre-zxqy again", 4)
        screen.send("\x1b\x7f", 0.45)  # Alt+Backspace also kills the last word
        screen.wait_for("pre-zxqy ", 4)
        visible = screen.terminal.text()
        if "again" in visible:
            raise AssertionError(f"Alt+Backspace left the killed word on screen\n--- screen ---\n{visible}")
        screen.send("fwdkill more", 0.4)
        screen.wait_for("pre-zxqy fwdkill more", 4)
        screen.send("\x01", 0.3)  # Ctrl+A
        for _ in range(9):  # land on "fwdkill"
            screen.send("\x1b[C", 0.05)
        screen.send("\x1bd", 0.45)  # Alt+D kills "fwdkill"
        screen.wait_for("pre-zxqy  more", 4)
        visible = screen.terminal.text()
        if "fwdkill" in visible:
            raise AssertionError(f"Alt+D left the killed word on screen\n--- screen ---\n{visible}")
        screen.send("\x15", 0.45)  # Ctrl+U clears before Ctrl+T / Ctrl+K probes
        screen.wait_for("Ask Veasel", 4)
        screen.send("zt", 0.35)
        screen.wait_for("zt", 4)
        screen.send("\x14", 0.4)  # Ctrl+T at end swaps to "tz"
        screen.wait_for("tz", 4)
        visible = screen.terminal.text()
        if "zt" in visible:
            raise AssertionError(f"Ctrl+T left the unswapped draft on screen\n--- screen ---\n{visible}")
        screen.send("\x15", 0.4)
        screen.wait_for("Ask Veasel", 4)
        screen.send("capword", 0.35)
        screen.wait_for("capword", 4)
        screen.send("\x01", 0.3)  # Ctrl+A
        screen.send("\x1bc", 0.45)  # Alt+C capitalizes → Capword
        screen.wait_for("Capword", 4)
        visible = screen.terminal.text()
        if "capword" in visible:
            raise AssertionError(f"Alt+C left the uncapitalized draft on screen\n--- screen ---\n{visible}")
        screen.send("\x15", 0.4)
        screen.wait_for("Ask Veasel", 4)
        screen.send("mixCase", 0.35)
        screen.wait_for("mixCase", 4)
        screen.send("\x01", 0.3)
        screen.send("\x1bu", 0.45)  # Alt+U → MIXCASE
        screen.wait_for("MIXCASE", 4)
        visible = screen.terminal.text()
        if "mixCase" in visible:
            raise AssertionError(f"Alt+U left the mixed-case draft on screen\n--- screen ---\n{visible}")
        screen.send("\x01", 0.3)
        screen.send("\x1bl", 0.45)  # Alt+L → mixcase
        screen.wait_for("mixcase", 4)
        visible = screen.terminal.text()
        if "MIXCASE" in visible:
            raise AssertionError(f"Alt+L left the uppercased draft on screen\n--- screen ---\n{visible}")
        screen.send("\x15", 0.4)
        screen.wait_for("Ask Veasel", 4)
        # Ctrl+_ undoes Ctrl+U clear (readline undo; Ctrl+Y stays OSC-52 copy).
        screen.send("undostack", 0.35)
        screen.wait_for("undostack", 4)
        screen.send("\x15", 0.4)  # Ctrl+U clears
        screen.wait_for("Ask Veasel", 4)
        visible = screen.terminal.text()
        if "undostack" in visible:
            raise AssertionError(f"Ctrl+U left undostack on screen before undo\n--- screen ---\n{visible}")
        screen.send("\x1f", 0.5)  # Ctrl+_
        screen.wait_for("undostack", 4)
        visible = screen.terminal.text()
        if "undostack" not in visible:
            raise AssertionError(f"Ctrl+_ did not restore the cleared draft\n--- screen ---\n{visible}")
        screen.send("\x15", 0.4)
        screen.wait_for("Ask Veasel", 4)
        # Alt+Y yanks the latest kill; Ctrl+Y remains OSC-52 last-reply clipboard.
        screen.send("killring", 0.35)
        screen.wait_for("killring", 4)
        screen.send("\x15", 0.4)  # Ctrl+U kills into the ring
        screen.wait_for("Ask Veasel", 4)
        visible = screen.terminal.text()
        if "killring" in visible:
            raise AssertionError(f"Ctrl+U left killring on screen before Alt+Y\n--- screen ---\n{visible}")
        screen.send("\x1by", 0.5)  # Alt+Y yank
        screen.wait_for("killring", 4)
        visible = screen.terminal.text()
        if "killring" not in visible:
            raise AssertionError(f"Alt+Y did not yank the killed draft\n--- screen ---\n{visible}")
        screen.send("\x19", 0.5)  # Ctrl+Y still copies last assistant reply (not yank)
        screen.wait_for("Copied last reply", 4)
        screen.send("\x1b", 0.35)  # dismiss copy notice; composer may still hold killring
        screen.send("\x15", 0.4)  # clear yanked draft before the next probe
        screen.wait_for("Ask Veasel", 4)
        screen.send("ml-one", 0.35)
        screen.wait_for("ml-one", 4)
        screen.send("\n", 0.4)  # Ctrl+J / linefeed inserts a newline (does not submit)
        screen.send("ml-two", 0.35)
        screen.wait_for("ml-one", 4)
        screen.wait_for("ml-two", 4)
        visible = screen.terminal.text()
        if "ml-one" not in visible or "ml-two" not in visible:
            raise AssertionError(f"Ctrl+J did not keep a multiline draft\n--- screen ---\n{visible}")
        screen.send("\x1b[27;2;13~", 0.4)  # Shift+Enter inserts another newline
        screen.send("ml-three", 0.35)
        screen.wait_for("ml-three", 4)
        visible = screen.terminal.text()
        if "ml-three" not in visible:
            raise AssertionError(f"Shift+Enter did not extend the multiline draft\n--- screen ---\n{visible}")
        screen.send("\x15", 0.4)
        screen.wait_for("Ask Veasel", 4)
        visible = screen.terminal.text()
        if "ml-one" in visible or "ml-two" in visible or "ml-three" in visible:
            raise AssertionError(f"Ctrl+U left the multiline draft on screen\n--- screen ---\n{visible}")
        screen.send("headTAIL", 0.4)
        screen.wait_for("headTAIL", 4)
        screen.send("\x01", 0.3)  # start of draft
        for _ in range(4):  # move past "head"
            screen.send("\x1b[C", 0.08)
        screen.send("\x0b", 0.45)  # Ctrl+K kills from cursor to end
        screen.wait_for("head", 4)
        visible = screen.terminal.text()
        if "TAIL" in visible:
            raise AssertionError(f"Ctrl+K left text after the cursor\n--- screen ---\n{visible}")
        screen.send("\x15", 0.45)  # Ctrl+U clears the composer draft
        screen.wait_for("Ask Veasel", 4)
        visible = screen.terminal.text()
        if "head" in visible:
            raise AssertionError(f"Ctrl+U left the composer draft on screen\n--- screen ---\n{visible}")
        screen.send("one two three", 0.4)
        screen.wait_for("one two three", 4)
        screen.send("\x01", 0.3)  # Ctrl+A
        screen.send("\x1b[1;5C", 0.25)  # Ctrl+→ → after "one "
        screen.send("\x1b[1;5C", 0.25)  # Ctrl+→ → after "two "
        screen.send("\x0b", 0.4)  # Ctrl+K drops "three"
        screen.wait_for("one two ", 4)
        visible = screen.terminal.text()
        if "three" in visible:
            raise AssertionError(f"Ctrl+→ did not land before the last word\n--- screen ---\n{visible}")
        screen.send("\x15", 0.4)
        screen.wait_for("Ask Veasel", 4)
        screen.send("abf-one abf-two abf-three", 0.4)
        screen.wait_for("abf-one abf-two abf-three", 4)
        screen.send("\x01", 0.3)  # Ctrl+A
        screen.send("\x1bf", 0.3)  # Alt+F → after "abf-one "
        screen.send("\x1bf", 0.3)  # Alt+F → after "abf-two "
        screen.send("\x1bb", 0.3)  # Alt+B → start of "abf-two"
        screen.send("\x0b", 0.4)  # Ctrl+K drops "abf-two abf-three"
        screen.wait_for("abf-one ", 4)
        visible = screen.terminal.text()
        if "abf-two" in visible or "abf-three" in visible:
            raise AssertionError(f"Alt+B/F did not land before abf-two\n--- screen ---\n{visible}")
        screen.send("\x15", 0.4)
        screen.wait_for("Ask Veasel", 4)
        screen.send("\x1b[A", 0.45)  # ↑ recalls last submitted prompt
        screen.send("!", 0.35)  # append so the recalled line is unique on screen
        screen.wait_for("keep this prompt!", 4)
        screen.send("\x15", 0.45)  # Ctrl+U clears the recalled draft
        screen.wait_for("Ask Veasel", 4)
        visible = screen.terminal.text()
        if "keep this prompt!" in visible:
            raise AssertionError(f"Ctrl+U left the recalled draft on screen\n--- screen ---\n{visible}")
        state["next_message"] = "cancel"
        screen.send("stop this\r", 0.45)
        screen.wait_for("busy")
        # Multi-delta live stream: stick-to-bottom shows measured growth, Home
        # advertises End-follow, End restores follow + busy, then Esc cancels
        # while scrolled again.
        screen.wait_for("stream line 12", 6)
        screen.wait_for("streaming  ·  ", 4)
        screen.wait_for("chars", 4)
        time.sleep(0.35)
        # Home jumps to the earliest window (composer empty). Footer status is
        # reliable even when the in-panel ▼ cue is clipped under the composer.
        screen.send("\x1b[H", 0.45)  # Home while streaming
        screen.wait_for("scrolled  ·  streaming below · End follows", 4)
        visible = screen.terminal.text()
        if "stream line 01" not in visible:
            raise AssertionError(f"Home did not reveal the start of the live stream\n--- screen ---\n{visible}")
        screen.send("\x1b[F", 0.45)  # End re-follows the live tail
        screen.wait_for("streaming  ·  ", 4)
        screen.wait_for("chars", 4)
        time.sleep(0.2)
        visible = screen.terminal.text()
        if "scrolled  ·  streaming below · End follows" in visible:
            raise AssertionError(f"End did not clear the scroll-follow status\n--- screen ---\n{visible}")
        if "STREAM-TAIL" not in visible and "stream line 3" not in visible:
            raise AssertionError(f"End did not return to the live stream tail\n--- screen ---\n{visible}")
        screen.send("\x1b[H", 0.45)  # Home again before cancel-while-scrolled
        screen.wait_for("scrolled  ·  streaming below · End follows", 4)
        screen.send("\x1b", 0.4)  # Esc cancels while scrolled — never leaves
        screen.wait_for("Turn cancelled.", 6)
        screen.wait_for("cancelled  ·  response cancelled", 4)
        screen.wait_for("stop this")
        screen.wait_for("Ask Veasel", 4)  # still in session after scrolled cancel
        screen.send("\x1b", 0.35)  # dismiss notice overlay if any
        screen.send("\x1b", 0.45)  # leave session
        screen.wait_for("q quit")
        screen.send("Lane-19", 0.55)  # type-to-filter home sessions
        screen.wait_for("Filter  1/20 match", 4)
        screen.wait_for("filter", 4)
        screen.wait_for("session 1 of 1 match", 4)
        screen.wait_for("Ctrl+L clear", 4)
        screen.wait_for("Esc clear", 4)
        screen.wait_for("Lane-19")
        visible = screen.terminal.text()
        if "Alpha" in visible or "Beta" in visible:
            raise AssertionError(f"session filter left unmatched rows on screen\n--- screen ---\n{visible}")
        screen.send("\x0c", 0.4)  # Ctrl+L clears session filter
        screen.wait_for("Alpha", 4)
        screen.send("\x1b[F", 0.35)  # End → last session
        screen.wait_for("Selected 20 of 20", 4)
        screen.wait_for("Lane-19")
        visible = screen.terminal.text()
        if "Alpha" in visible or "Beta" in visible:
            raise AssertionError(f"session list left earlier rows on screen\n--- screen ---\n{visible}")
        screen.send("\x1b[H", 0.35)  # Home → first session
        screen.wait_for("Selected 1 of 20", 4)
        screen.wait_for("Alpha")
        screen.send("\x1b[6~", 0.25)  # PgDn
        screen.wait_for("Selected ", 4)
        screen.send("\x1b[5~", 0.25)  # PgUp
        screen.wait_for("Selected 1 of 20", 4)
        screen.wait_for("Alpha")
        state["hold_edits"] = True
        state["hold_other_edits"] = True
        screen.send("\r", 0.5)
        screen.wait_for("Ask Veasel")
        screen.send("/patch ", 0.2)
        screen.send("\x1b", 0.2)  # clear slash menu
        screen.send("\x1b", 0.3)  # dismiss notice if any
        screen.send("\x1b", 0.4)  # leave session
        screen.wait_for("q quit")
        screen.send("j", 0.25)
        screen.send("\r", 0.55)
        screen.wait_for("Ask Veasel")
        screen.send("/patch show ", 0.35)
        screen.wait_for("No file edits are waiting")
        time.sleep(2.2)
        screen.read_for(0.3)
        visible = screen.terminal.text()
        if "aaaaaaaa-aaaa" in visible:
            raise AssertionError(f"stale edit from the previous session was offered\n--- screen ---\n{visible}")
        if "No file edits are waiting" not in visible:
            raise AssertionError(f"empty edit list disappeared after the late response\n--- screen ---\n{visible}")
        screen.send("\x1b", 0.2)
        screen.clear_line(12)  # "/patch show "
        screen.send("/command ", 0.45)
        screen.send("\t", 0.45)
        screen.wait_for("No shell commands are waiting")
        state["edits_release"].set()
        state["other_edits_release"].set()
        process.terminate()
        process.wait(timeout=2)
        exercise_narrow(port)
    finally:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
        server.shutdown()
    print("keyboard exercise passed")


if __name__ == "__main__":
    main()
