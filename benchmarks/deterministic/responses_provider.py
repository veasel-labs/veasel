#!/usr/bin/env python3
"""Scripted OpenAI Responses provider for the Codex adapter.

First request -> one shell function_call that writes src/main.v.
Follow-up (function_call_output present) -> final message.
Logs requests to argv[2].
"""
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

port_file, log_file = sys.argv[1], sys.argv[2]
CONTENT = "module fixture\n\n// workspace-search-sentinel\nfn greet(name string) string {\n\treturn 'Hello, ${name}!'\n}\n"
WRITE_CMD = "cat > src/main.v <<'VEASEL_EOF'\n" + CONTENT + "VEASEL_EOF"

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        self.send_response(404); self.end_headers()
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        payload = json.loads(body or b"{}")
        Path(log_file).open("a").write(json.dumps({"path": self.path, "payload": payload}) + "\n")
        items = payload.get("input", [])
        has_tool_output = any(isinstance(i, dict) and i.get("type") == "function_call_output" for i in items)
        if has_tool_output:
            output = [{"type": "message", "id": "msg-1", "role": "assistant",
                       "content": [{"type": "output_text", "text": "Done. The greet function is in place."}]}]
        else:
            output = [{"type": "function_call", "id": "fc-1", "call_id": "call-1",
                       "name": "exec_command", "arguments": json.dumps({"cmd": WRITE_CMD}), "status": "completed"}]
        resp = {"id": "resp-1", "object": "response", "created_at": 0, "model": payload.get("model", "smoke-model"),
                "output": output, "status": "completed",
                "usage": {"input_tokens": 24, "output_tokens": 12, "total_tokens": 36}}
        if payload.get("stream"):
            # Minimal Responses SSE: created -> output items -> completed
            events = []
            created = {"type": "response.created", "response": {**resp, "output": [], "status": "in_progress"}}
            events.append(created)
            for idx, item in enumerate(output):
                events.append({"type": "response.output_item.added", "output_index": idx, "item": {**item, "content": []} if item["type"]=="message" else item})
                if item["type"] == "message":
                    events.append({"type": "response.content_part.added", "item_id": item["id"], "output_index": idx, "content_index": 0, "part": {"type": "output_text", "text": "", "annotations": []}})
                    events.append({"type": "response.output_text.delta", "item_id": item["id"], "output_index": idx, "content_index": 0, "delta": item["content"][0]["text"]})
                    events.append({"type": "response.output_text.done", "item_id": item["id"], "output_index": idx, "content_index": 0, "text": item["content"][0]["text"]})
                    events.append({"type": "response.content_part.done", "item_id": item["id"], "output_index": idx, "content_index": 0, "part": item["content"][0]})
                if item["type"] == "function_call":
                    events.append({"type": "response.function_call_arguments.delta", "item_id": item["id"], "output_index": idx, "delta": item["arguments"]})
                    events.append({"type": "response.function_call_arguments.done", "item_id": item["id"], "output_index": idx, "arguments": item["arguments"]})
                events.append({"type": "response.output_item.done", "output_index": idx, "item": item})
            events.append({"type": "response.completed", "response": resp})
            data = "".join(f"event: {e['type']}\ndata: {json.dumps(e)}\n\n" for e in events).encode()
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
