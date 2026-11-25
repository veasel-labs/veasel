#!/usr/bin/env python3
"""Unit tests for the packaged shared-listener acceptance harness."""
from __future__ import annotations

import importlib.util
import os
import pathlib
import unittest
from unittest.mock import patch


SCRIPT = pathlib.Path(__file__).with_name("packaged-shared-listener-smoke.py")
SPEC = importlib.util.spec_from_file_location("shared_listener_smoke", SCRIPT)
assert SPEC and SPEC.loader
smoke = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(smoke)


class CleanEnvironmentTests(unittest.TestCase):
    def test_does_not_inherit_credentials_proxies_or_host_sockets(self) -> None:
        home = pathlib.Path("/tmp/isolated-home")
        data = pathlib.Path("/tmp/isolated-data")
        temp = pathlib.Path("/tmp/isolated-temp")

        injected = {
            "OPENAI_API_KEY": "must-not-escape",
            "ANTHROPIC_API_KEY": "must-not-escape",
            "AWS_SECRET_ACCESS_KEY": "must-not-escape",
            "HTTP_PROXY": "http://user:secret@proxy.invalid:8080",
            "HTTPS_PROXY": "http://user:secret@proxy.invalid:8080",
            "ALL_PROXY": "socks5://user:secret@proxy.invalid:1080",
            "DBUS_SESSION_BUS_ADDRESS": "unix:path=/host/session-bus",
            "DISPLAY": ":0",
            "WAYLAND_DISPLAY": "wayland-0",
            "VEASEL_BACKEND_BIN": "/host/backend",
            "VEASEL_E2E_BACKEND_BIN": "/host/e2e-backend",
        }
        with patch.dict(os.environ, injected, clear=False):
            env = smoke.clean_environment(home, data, temp, 12345)

        for name in (
            "OPENAI_API_KEY",
            "ANTHROPIC_API_KEY",
            "AWS_SECRET_ACCESS_KEY",
            "HTTP_PROXY",
            "HTTPS_PROXY",
            "ALL_PROXY",
            "DBUS_SESSION_BUS_ADDRESS",
            "DISPLAY",
            "WAYLAND_DISPLAY",
            "VEASEL_BACKEND_BIN",
            "VEASEL_E2E_BACKEND_BIN",
        ):
            with self.subTest(name=name):
                self.assertNotIn(name, env)

        self.assertEqual(env["HOME"], str(home))
        self.assertEqual(env["VEASEL_DATA_DIR"], str(data))
        self.assertEqual(env["VEASEL_PORT"], "12345")
        self.assertEqual(env["PATH"], "/usr/bin:/bin")
        self.assertEqual(env["LC_ALL"], "C.UTF-8")


if __name__ == "__main__":
    unittest.main()
