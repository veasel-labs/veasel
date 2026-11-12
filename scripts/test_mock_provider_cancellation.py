#!/usr/bin/env python3
"""Regression tests for uniquely correlated cancellation fixture requests."""

import importlib.util
import unittest
from pathlib import Path


def load_mock():
    path = Path(__file__).with_name("mock-provider.py")
    spec = importlib.util.spec_from_file_location("veasel_mock_provider_cancellation", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class CancellationCorrelationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mock = load_mock()

    def test_raw_chat_payload_preserves_unique_cancellation_prompt(self):
        operation_id = "4541c142-8afe-4f50-ae8a-ec54007d1a69"
        prompt = f"Wait for cancellation {operation_id}"
        payload = {
            "messages": [
                {"role": "user", "content": prompt},
            ],
        }

        # Exercise the reported failure mode: the parsed fixture text is the
        # generic old marker, but the request body contains the unique ID.
        marker_prompt = self.mock.cancellation_fixture_prompt(payload, "Wait for cancellation")
        self.assertEqual(marker_prompt, prompt)
        self.assertEqual(
            f"SLOW_PROVIDER_REQUEST_STARTED:{marker_prompt}",
            f"SLOW_PROVIDER_REQUEST_STARTED:{prompt}",
        )

    def test_generic_cancellation_prompt_remains_supported(self):
        payload = {"messages": [{"role": "user", "content": "Wait for cancellation"}]}
        self.assertEqual(
            self.mock.cancellation_fixture_prompt(payload),
            "Wait for cancellation",
        )

    def test_unrelated_prompt_does_not_create_cancellation_marker(self):
        payload = {"messages": [{"role": "user", "content": "Say hello"}]}
        self.assertEqual(self.mock.cancellation_fixture_prompt(payload, "Say hello"), "")


if __name__ == "__main__":
    unittest.main()
