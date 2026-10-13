import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if (
            self.path != "/v1/chat/completions"
            or self.headers.get("Authorization") != "Bearer test-only-key"
        ):
            self.send_error(401)
            return
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = request.get("messages", [])
        if not any(
            message.get("role") == "user"
            and "hello.txt" in message.get("content", "")
            for message in messages
        ):
            self.send_error(400, "unexpected smoke-task prompt")
            return
        tools = request.get("tools", [])
        available = {
            tool.get("function", {}).get("name") for tool in tools
        }
        previous_tool_result = next(
            (
                message.get("content", "")
                for message in reversed(messages)
                if message.get("role") == "tool"
            ),
            None,
        )
        if previous_tool_result is None:
            name = "workspace_propose_file_edit"
            if name not in available:
                self.send_error(400, "Veasel did not expose workspace file edit")
                return
            delta = {
                "tool_calls": [{
                    "index": 0,
                    "id": "harbor-smoke-edit-1",
                    "type": "function",
                    "function": {
                        "name": name,
                        "arguments": json.dumps(
                            {"path": "hello.txt", "content": "Harbor adapter works.\n"}
                        ),
                    },
                }],
            }
        else:
            assistant_call = next(
                (
                    call
                    for message in messages
                    if message.get("role") == "assistant"
                    for call in message.get("tool_calls", [])
                ),
                {},
            )
            tool_result = next(
                (
                    message
                    for message in reversed(messages)
                    if message.get("role") == "tool"
                ),
                {},
            )
            if (
                assistant_call.get("id") != tool_result.get("tool_call_id")
                or "Applied by explicit autonomous benchmark policy"
                not in tool_result.get("content", "")
            ):
                self.send_error(400, "expected a successfully applied workspace edit")
                return
            delta = {"content": "Created hello.txt."}
        chunk = {
            "id": "harbor-local-fixture",
            "object": "chat.completion.chunk",
            "created": 0,
            "model": request.get("model", "smoke-model"),
            "choices": [{
                "index": 0,
                "delta": delta,
                "finish_reason": "tool_calls" if previous_tool_result is None else "stop",
            }],
        }
        body = (
            "data: "
            + json.dumps(chunk)
            + "\n\n"
            + "data: [DONE]\n\n"
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        print(format % args, flush=True)


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
