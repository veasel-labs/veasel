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
    "sse_id": 0,
}


def review_diff() -> str:
    lines = [
        "diff --git a/src/main.v b/src/main.v",
        "--- a/src/main.v",
        "+++ b/src/main.v",
        "@@ -1,2 +1,3 @@",
        "-old line",
    ]
    lines.extend(f"+kept line {index:02d}" for index in range(1, 29))
    lines.append("+TAIL-SENTINEL")
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
            return self._json(200, settings_view())
        if path == f"/v1/sessions/{SESSION}/workspace/edits/{EDIT_ID}":
            return self._json(200, {
                "id": EDIT_ID,
                "session_id": SESSION,
                "path": "src/main.v",
                "status": "pending",
                "diff": review_diff(),
            })
        if path == f"/v1/sessions/{SESSION}/workspace/edits":
            if state["hold_edits"]:
                state["edits_release"].wait(3.0)
            return self._json(200, [{
                "id": EDIT_ID, "path": "src/main.v", "status": "pending",
            }])
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
                "status": "pending",
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
                return self._json(200, [{
                    "id": CALL_ID, "plugin_name": "review-tools", "tool_name": "effect", "status": "pending",
                    "arguments_bytes": len(long_mcp_arguments()),
                }])
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
                "status": "pending",
                "exit_code": 0,
                "output": "",
                "created_at": "",
                "updated_at": "",
            })
        if path == f"/v1/sessions/{SESSION}/workspace/commands":
            return self._json(200, [{
                "id": COMMAND_ID, "command": "echo hi", "cwd": ".", "timeout_seconds": 10,
                "status": "pending", "exit_code": 0, "output": "", "created_at": "", "updated_at": "",
            }])
        if path == "/v1/plugins":
            return self._json(200, {"plugins": [{
                "name": "review-tools",
                "skills": [{"name": "review", "description": "Review code", "allowed_tools_declared": False, "allowed_tools": []}],
                "mcp_servers": [{"name": "local", "transport": "stdio", "command": "node server.js", "url_origin": "", "header_count": 0, "header_names": []}],
            }], "diagnostics": []})
        if path == "/v1/events":
            return self._sse()
        self._json(404, {"error": "not found"})

    def do_POST(self) -> None:
        path = urllib.parse.urlparse(self.path).path
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b""
        if path == "/v1/config/model":
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
        if path == f"/v1/sessions/{SESSION}/messages":
            body = json.loads(raw.decode())
            operation = self.headers.get("X-Veasel-Operation-ID", "")
            if state["next_message"] == "cancel":
                state["pending_op"] = operation
                state["pending_user"] = body["content"]
                return self._json(202, {"operation_id": operation, "status": "running"})
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
        screen.wait_for("quit (home)")
        screen.send("s", 0.5)
        screen.wait_for("OpenAI")
        screen.wait_for("1 OF 3")
        screen.send("\r", 0.6)
        screen.wait_for("2 OF 3")
        screen.wait_for("API key")
    finally:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()


def main() -> None:
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    rows, cols = 40, 100
    process, master = launch(port, rows, cols)
    screen = Screen(master, rows, cols)
    try:
        screen.wait_for("Alpha", 8)
        screen.send("s", 0.5)
        screen.wait_for("Choose a provider")
        screen.wait_for("1 OF 3")
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
        screen.wait_for("/connect · s to manage providers")
        saved = state["saved"] or {}
        if saved.get("model") != "gpt-5" or not saved.get("api_key"):
            raise AssertionError("selected model and api key were not saved")
        screen.send("\r", 0.6)
        screen.wait_for("Ask Veasel")
        # Description search: find /connect and /theme without typing their names.
        screen.send("/key", 0.7)
        screen.wait_for("/connect")
        screen.send("\x1b", 0.25)
        screen.clear_line(4)  # "/key"
        screen.send("/color", 0.7)
        screen.wait_for("/theme")
        screen.send("\x1b", 0.25)
        screen.clear_line(6)  # "/color"
        screen.send("/patch ", 0.8)
        screen.wait_for("approve")
        screen.send("\t", 0.4)
        screen.wait_for("/patch show")
        screen.send(" ", 0.6)
        screen.wait_for("aaaaaaaa-aaaa")
        screen.send("\x1b", 0.25)
        screen.clear_line(13)  # "/patch show "
        screen.send(f"/patch show {EDIT_ID}\r", 0.7)
        screen.wait_for("29 added, 1 removed", 4)
        screen.wait_for("Showing ")
        reviewed = screen.terminal.text()
        if "TAIL-SENTINEL" in reviewed:
            raise AssertionError(f"diff review showed lines past the terminal budget\n--- screen ---\n{reviewed}")
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
        state["next_message"] = "cancel"
        screen.send("stop this\r", 0.45)
        screen.wait_for("thinking")
        time.sleep(0.35)
        screen.send("\x1b", 0.4)
        screen.wait_for("Turn cancelled.", 6)
        screen.wait_for("stop this")
        screen.send("\x1b", 0.45)
        screen.wait_for("quit (home)")
        for _ in range(19):
            screen.send("j", 0.04)
        screen.wait_for("20/20", 4)
        screen.wait_for("Lane-19")
        visible = screen.terminal.text()
        if "Alpha" in visible or "Beta" in visible:
            raise AssertionError(f"session list left earlier rows on screen\n--- screen ---\n{visible}")
        for _ in range(19):
            screen.send("k", 0.04)
        screen.wait_for("1/20", 4)
        screen.wait_for("Alpha")
        state["hold_edits"] = True
        state["hold_other_edits"] = True
        screen.send("\r", 0.5)
        screen.wait_for("Ask Veasel")
        screen.send("/patch ", 0.2)
        screen.send("\x1b", 0.15)
        screen.send("\x1b", 0.3)
        screen.wait_for("quit (home)")
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
