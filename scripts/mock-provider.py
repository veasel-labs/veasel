#!/usr/bin/env python3
"""Deterministic local endpoint fixtures for the provider API smoke test."""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


API_KEYS = {
    "openai-compatible": "veasel-openai-key",
    "anthropic": "veasel-anthropic-key",
    "gemini": "veasel-gemini-key",
}
REPLY = "Provider fixture reply"
SESSION_SYSTEM = (
    "You are Veasel Code, a coding assistant. You can explain code and help plan changes, "
    "but this version cannot inspect or edit repository files or execute commands. "
    "Never claim that you performed actions."
)


class MockProvider(BaseHTTPRequestHandler):
    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/redirect/v1/chat/completions":
            self.send_response(302)
            self.send_header("Location", "/v1/chat/completions")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.headers.get("Authorization") == f"Bearer {API_KEYS['openai-compatible']}":
            if (
                self.path != "/v1/chat/completions"
                or payload.get("model") != "smoke-model"
                or payload.get("max_tokens") != 4096
                or payload.get("messages", [])[0].get("content")
                not in ("Be concise", SESSION_SYSTEM)
                or payload.get("messages", [])[-1].get("content")
                not in ("Say hello", "Continue this session")
            ):
                self.send_error(400)
                return
            body = {
                "choices": [{"message": {"role": "assistant", "content": REPLY}}]
            }
        elif self.headers.get("x-api-key") == API_KEYS["anthropic"]:
            if (
                self.path != "/v1/messages"
                or payload.get("model") != "smoke-model"
                or payload.get("max_tokens") != 4096
                or payload.get("system") not in ("Be concise", SESSION_SYSTEM)
                or payload.get("messages", [])[-1].get("content")
                not in ("Say hello", "Continue this session")
            ):
                self.send_error(400)
                return
            body = {"content": [{"type": "text", "text": REPLY}]}
        elif self.headers.get("x-goog-api-key") == API_KEYS["gemini"]:
            if (
                self.path != "/v1beta/models/smoke-model:generateContent"
                or payload.get("systemInstruction", {}).get("parts", [])[0].get("text")
                not in ("Be concise", SESSION_SYSTEM)
                or payload.get("generationConfig", {}).get("maxOutputTokens") != 4096
                or payload.get("contents", [])[-1].get("parts", [])[0].get("text")
                not in ("Say hello", "Continue this session")
            ):
                self.send_error(400)
                return
            body = {
                "candidates": [
                    {"content": {"role": "model", "parts": [{"text": REPLY}]}}
                ]
            }
        else:
            self.send_error(401)
            return

        encoded = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, _format, *_args):
        return


if __name__ == "__main__":
    port_file = Path(sys.argv[1])
    server = HTTPServer(("127.0.0.1", 0), MockProvider)
    port_file.write_text(str(server.server_address[1]))
    server.serve_forever()
