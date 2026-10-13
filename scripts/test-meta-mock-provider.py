import json
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen


SCRIPT = Path(__file__).with_name("mock-provider.py")


class MetaMockProviderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp_dir = tempfile.TemporaryDirectory(prefix="veasel-meta-mock-")
        cls.port_file = Path(cls.temp_dir.name) / "provider.port"
        cls.server = subprocess.Popen(
            [sys.executable, str(SCRIPT), str(cls.port_file)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.STDOUT,
        )
        deadline = time.monotonic() + 5
        while not cls.port_file.exists() and time.monotonic() < deadline:
            if cls.server.poll() is not None:
                raise RuntimeError("mock Meta provider exited before becoming ready")
            time.sleep(0.05)
        if not cls.port_file.exists():
            cls.server.terminate()
            raise RuntimeError("mock Meta provider did not become ready")
        cls.endpoint = f"http://127.0.0.1:{cls.port_file.read_text()}/v1/responses"

    @classmethod
    def tearDownClass(cls):
        cls.server.terminate()
        cls.server.wait(timeout=5)
        cls.temp_dir.cleanup()

    def post_response(self, input_items):
        request = Request(
            self.endpoint,
            data=json.dumps({
                "model": "muse-wonder-1.0",
                "input": input_items,
                "max_output_tokens": 4096,
                "store": False,
                "reasoning": {"effort": "high", "summary": "auto"},
                "include": ["reasoning.encrypted_content"],
                "tools": [{"type": "function", "name": "workspace_search", "parameters": {}}],
            }).encode(),
            headers={
                "Authorization": "Bearer veasel-meta-key",
                "Content-Type": "application/json",
            },
        )
        try:
            with urlopen(request, timeout=3) as response:
                return json.load(response)
        except HTTPError as error:
            self.fail(f"mock provider returned HTTP {error.code}: {error.read().decode()}")

    def test_tool_followup_finishes_then_a_later_tool_call_gets_a_new_id(self):
        conversation = [
            {"role": "system", "content": "Use the available tools when needed."},
            {"type": "message", "role": "user", "content": "Inspect workspace"},
        ]
        first_response = self.post_response(conversation)
        first_call = next(item for item in first_response["output"] if item["type"] == "function_call")
        self.assertEqual(first_call["call_id"], "meta-call-1")

        follow_up = conversation + first_response["output"] + [{
            "type": "function_call_output",
            "call_id": first_call["call_id"],
            "output": "Found workspace-search-sentinel",
        }]
        final_response = self.post_response(follow_up)
        self.assertEqual(final_response["output"][0]["type"], "message")
        self.assertEqual(
            final_response["output"][0]["content"][0]["text"],
            "Found workspace-search-sentinel",
        )

        next_turn = follow_up + final_response["output"] + [
            {"type": "message", "role": "user", "content": "Inspect workspace"},
        ]
        second_response = self.post_response(next_turn)
        second_call = next(item for item in second_response["output"] if item["type"] == "function_call")
        self.assertEqual(second_call["call_id"], "meta-call-2")


if __name__ == "__main__":
    unittest.main()
