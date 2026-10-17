#!/usr/bin/env python3
"""Generic deterministic OpenAI-chat provider for competitor spikes.

First non-tool request -> one write/edit tool call for src/main.v using the
agent's own advertised tool schema. Tool-result follow-up -> final text.
Logs every request to argv[2] for inspection.
"""
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

port_file, log_file = sys.argv[1], sys.argv[2]
CONTENT = "module fixture\n\n// workspace-search-sentinel\nfn greet(name string) string {\n\treturn 'Hello, ${name}!'\n}\n"

ARGS = {
    "write": lambda: {"path": "src/main.v", "content": CONTENT},
    "edit": lambda: {"path": "src/main.v", "oldString": "// workspace-search-sentinel", "newString": "// workspace-search-sentinel\nfn greet(name string) string {\n\treturn 'Hello, ${name}!'\n}"},
    "create_file": lambda: {"path": "src/main.v", "content": CONTENT},
    "apply_patch": lambda: {"patch": CONTENT},
}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            data = json.dumps({"object": "list", "data": [
                {"id": "smoke-model", "object": "model", "created": 0, "owned_by": "fixture"}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_response(404); self.end_headers()
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        payload = json.loads(body or b"{}")
        Path(log_file).open("a").write(json.dumps({"path": self.path, "payload": payload}) + "\n")
        msgs = payload.get("messages", [])
        last = msgs[-1] if msgs else {}
        tools = payload.get("tools", [])
        names = [t.get("function", {}).get("name", "") for t in tools]
        if last.get("role") == "tool":
            reply = {"role": "assistant", "content": "Done. The greet function is in place."}
            finish = "stop"
            msg = reply
        else:
            pick = next((n for n in ("write", "edit", "create_file", "apply_patch") if n in names), None)
            if pick is None:
                msg = {"role": "assistant", "content": "No write tool available."}
                finish = "stop"
            else:
                msg = {"role": "assistant", "content": None, "tool_calls": [
                    {"id": "call-1", "type": "function",
                     "function": {"name": pick, "arguments": json.dumps(ARGS[pick]())}}]}
                finish = "tool_calls"
        resp = {"id": "chatcmpl-fixture", "object": "chat.completion", "created": 0,
                "model": payload.get("model", "smoke-model"),
                "choices": [{"index": 0, "message": msg, "finish_reason": finish}],
                "usage": {"prompt_tokens": 24, "completion_tokens": 12, "total_tokens": 36}}
        # OpenCode (AI SDK) streams by default: honor stream flag with SSE.
        if payload.get("stream"):
            chunk = {"id": "chatcmpl-fixture", "object": "chat.completion.chunk", "created": 0,
                     "model": resp["model"],
                     "choices": [{"index": 0, "delta": msg, "finish_reason": None}]}
            tail = {"id": "chatcmpl-fixture", "object": "chat.completion.chunk", "created": 0,
                    "model": resp["model"],
                    "choices": [{"index": 0, "delta": {}, "finish_reason": finish}],
                    "usage": resp["usage"]}
            data = f"data: {json.dumps(chunk)}\n\ndata: {json.dumps(tail)}\n\ndata: [DONE]\n\n".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        data = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
Path(port_file).write_text(str(srv.server_address[1]))
srv.serve_forever()
