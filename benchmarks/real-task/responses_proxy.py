"""Small, single-purpose budget proxy for matched Responses API benchmarks.

The proxy intentionally supports only one model and one POST route. It does
not retry, follow redirects, log request bodies, or expose a metrics endpoint.
"""

from __future__ import annotations

import hmac
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
from typing import Any


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req: Request, fp: Any, code: int, msg: str, headers: Any,
                         newurl: str) -> None:
        return None


class BudgetProxy:
    MAX_RESPONSE_BYTES = 2 * 1024 * 1024

    def __init__(self, upstream_base_url: str, api_key: str, model: str,
                 max_requests: int, context_tokens: int, output_tokens: int,
                 client_api_key: str, max_request_body_bytes: int | None = None) -> None:
        parsed = urlsplit(upstream_base_url)
        local_fixture = parsed.hostname in {"127.0.0.1", "localhost", "::1"}
        if (parsed.scheme != "https" and not (parsed.scheme == "http" and local_fixture)) \
                or not parsed.hostname or parsed.username or parsed.password \
                or parsed.query or parsed.fragment:
            raise ValueError("upstream must be a credential-free HTTPS base URL")
        if not local_fixture and (parsed.hostname != "api.meta.ai" or parsed.path.rstrip("/") != "/v1"
                                  or parsed.port not in (None, 443)):
            raise ValueError("live upstream must be https://api.meta.ai/v1")
        if not api_key or not client_api_key or not model:
            raise ValueError("provider credential, client credential, and model are required")
        if any(value <= 0 for value in (max_requests, context_tokens, output_tokens)):
            raise ValueError("request and token budgets must be positive")
        self._upstream_base_url = upstream_base_url.rstrip("/")
        self._api_key = api_key
        self._model = model
        self._max_requests = max_requests
        self._context_tokens = context_tokens
        self._output_tokens = output_tokens
        # The body byte cap bounds transport size, not provider-billed tokens:
        # structured Responses framing and provider tokenization may add usage
        # not represented by UTF-8 body bytes. Non-text modalities are rejected
        # because remote media can expand beyond the request bytes.
        self._max_request_body_bytes = context_tokens if max_request_body_bytes is None else max_request_body_bytes
        if self._max_request_body_bytes <= 0:
            raise ValueError("request body byte cap must be positive")
        self._client_api_key = client_api_key.encode()
        self._lock = threading.Lock()
        self._attempts_reserved = 0
        self._max_request_body_bytes_seen = 0
        self._oversized_requests_rejected = 0
        self._httpd: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None
        self._opener = build_opener(_NoRedirect())

    def start(self) -> str:
        if self._httpd is not None:
            raise RuntimeError("proxy already started")
        proxy = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, _format: str, *_args: object) -> None:
                pass

            def _respond(self, status: int, payload: bytes) -> None:
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(payload)
                self.close_connection = True

            def do_GET(self) -> None:
                self._respond(405, b'{"error":"method_not_allowed"}')

            def do_POST(self) -> None:
                if self.path != "/v1/responses":
                    self._respond(404, b'{"error":"route_not_allowed"}')
                    return
                auth = self.headers.get("Authorization", "")
                supplied = auth[7:].encode() if auth.startswith("Bearer ") else b""
                if not hmac.compare_digest(supplied, proxy._client_api_key):
                    self._respond(401, b'{"error":"unauthorized"}')
                    return
                try:
                    size = int(self.headers.get("Content-Length", "-1"))
                except ValueError:
                    size = -1
                if size < 0 or size > proxy._max_request_body_bytes:
                    proxy._record_body_size(size, rejected=True)
                    self._respond(413, b'{"error":"request_too_large"}')
                    return
                if self.headers.get("Content-Encoding", "identity").lower() != "identity" \
                        or self.headers.get("Transfer-Encoding"):
                    self._respond(415, b'{"error":"request_encoding_not_allowed"}')
                    return
                proxy._record_body_size(size, rejected=False)
                body = self.rfile.read(size)
                if len(body) != size:
                    self._respond(400, b'{"error":"incomplete_request"}')
                    return
                try:
                    payload = json.loads(body)
                except (UnicodeDecodeError, json.JSONDecodeError):
                    self._respond(400, b'{"error":"invalid_json"}')
                    return
                if not isinstance(payload, dict) or payload.get("model") != proxy._model:
                    self._respond(400, b'{"error":"model_not_allowed"}')
                    return
                output = payload.get("max_output_tokens")
                if not isinstance(output, int) or isinstance(output, bool) or not 0 < output <= proxy._output_tokens:
                    self._respond(400, b'{"error":"output_budget_exceeded"}')
                    return
                if not _text_only_payload(payload):
                    self._respond(400, b'{"error":"non_text_input_not_allowed"}')
                    return
                if not proxy._reserve_attempt():
                    self._respond(429, b'{"error":"request_budget_exhausted"}')
                    return
                request = Request(
                    proxy._upstream_base_url + "/responses",
                    data=body,
                    headers={"Authorization": f"Bearer {proxy._api_key}",
                             "Content-Type": "application/json", "Accept": "text/event-stream, application/json"},
                    method="POST",
                )
                try:
                    with proxy._opener.open(request, timeout=300) as response:
                        if int(response.headers.get("Content-Length", "0") or "0") > proxy.MAX_RESPONSE_BYTES:
                            self._respond(502, b'{"error":"upstream_response_too_large"}')
                            return
                        forwarded_body = response.read(proxy.MAX_RESPONSE_BYTES + 1)
                        if len(forwarded_body) > proxy.MAX_RESPONSE_BYTES:
                            self._respond(502, b'{"error":"upstream_response_too_large"}')
                            return
                        status = response.status
                        content_type = response.headers.get("Content-Type", "application/json")
                except HTTPError as error:
                    try:
                        forwarded_body = error.read(65536)
                        status = error.code
                        content_type = "application/json"
                    finally:
                        error.close()
                except Exception:
                    self._respond(502, b'{"error":"upstream_request_failed"}')
                    return
                if 300 <= status < 400:
                    self._respond(502, b'{"error":"upstream_redirect_rejected"}')
                    return
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(forwarded_body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(forwarded_body)
                self.close_connection = True

        self._httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._httpd.daemon_threads = True
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)
        self._thread.start()
        return f"http://127.0.0.1:{self._httpd.server_port}/v1"

    def _reserve_attempt(self) -> bool:
        with self._lock:
            if self._attempts_reserved >= self._max_requests:
                return False
            self._attempts_reserved += 1
            return True

    def _record_body_size(self, size: int, rejected: bool) -> None:
        with self._lock:
            if size > self._max_request_body_bytes_seen:
                self._max_request_body_bytes_seen = size
            if rejected:
                self._oversized_requests_rejected += 1

    def metrics(self) -> dict[str, int]:
        with self._lock:
            return {"upstream_attempts_reserved": self._attempts_reserved,
                    "upstream_attempt_limit": self._max_requests,
                    "max_request_body_bytes_seen": self._max_request_body_bytes_seen,
                    "oversized_requests_rejected": self._oversized_requests_rejected}

    def close(self) -> None:
        httpd = self._httpd
        if httpd is None:
            return
        httpd.shutdown()
        httpd.server_close()
        if self._thread is not None:
            self._thread.join(timeout=2)
        self._httpd = None
        self._thread = None


def _text_only_payload(value: Any) -> bool:
    """Reject remote media or non-text content that bypasses byte accounting."""
    if isinstance(value, dict):
        if any(any(kind in key.lower() for kind in ("image", "audio", "video", "file")) for key in value):
            return False
        content_type = value.get("type")
        if isinstance(content_type, str) and any(part in content_type.lower() for part in ("image", "audio", "video", "file")):
            return False
        return all(_text_only_payload(item) for item in value.values())
    if isinstance(value, list):
        return all(_text_only_payload(item) for item in value)
    return True
