"""Unit tests for the Harbor 0.24.0 Veasel adapter contract."""

from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from harbor.agents.factory import AgentFactory
from harbor.models.agent.context import AgentContext

from benchmarks.harbor.veasel_agent import (
    VeaselCode,
    _veasel_provider,
    validate_trace,
)


class RecordingEnvironment:
    def __init__(self) -> None:
        self.calls: list[dict[str, object]] = []

    async def exec(self, **kwargs: object) -> SimpleNamespace:
        self.calls.append(kwargs)
        return SimpleNamespace(return_code=0, stdout="", stderr="")

    async def exec_as_agent(self, **kwargs: object) -> SimpleNamespace:
        self.calls.append(kwargs)
        return SimpleNamespace(return_code=0, stdout="", stderr="")


class VeaselHarborAdapterTests(unittest.IsolatedAsyncioTestCase):
    def test_provider_mapping_is_explicit(self) -> None:
        self.assertEqual(_veasel_provider("openai", "openai/gpt-test"), ("openai", "gpt-test"))
        self.assertEqual(_veasel_provider("google", "google/gemini-test"), ("gemini", "gemini-test"))
        self.assertEqual(
            _veasel_provider(
                "openai",
                "openai/gpt-test",
                "openai-compatible",
            ),
            ("openai-compatible", "gpt-test"),
        )
        self.assertEqual(
            _veasel_provider(
                "openai-compatible",
                "openai-compatible/gpt-test",
                "openai-compatible",
            ),
            ("openai-compatible", "gpt-test"),
        )
        with self.assertRaisesRegex(ValueError, "does not support"):
            _veasel_provider("amazon-bedrock", "amazon-bedrock/model")
        with self.assertRaisesRegex(ValueError, "does not match"):
            _veasel_provider("openai", "anthropic/model")
        with self.assertRaisesRegex(ValueError, "override must match"):
            _veasel_provider("anthropic", "anthropic/model", "openai-compatible")

    def test_harbor_factory_loads_documented_import_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            agent = AgentFactory.create_agent_from_import_path(
                "benchmarks.harbor.veasel_agent:VeaselCode",
                logs_dir=Path(directory),
                model_name="openai/gpt-test",
                veasel_version="1.2.3",
            )

        self.assertIsInstance(agent, VeaselCode)
        self.assertEqual(agent.name(), "veasel-code")
        self.assertEqual(agent.version(), "1.2.3")

    async def test_run_starts_isolated_server_and_exports_atif_without_forwarding_provider_env(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            agent = VeaselCode(
                logs_dir=Path(directory),
                model_name="openai/gpt-test",
                extra_env={"OPENAI_API_KEY": "fixture-secret"},
                veasel_version="1.2.3",
            )
            environment = RecordingEnvironment()

            await agent.run("Fix the fixture", environment, AgentContext())

        self.assertEqual(len(environment.calls), 1)
        call = environment.calls[0]
        command = str(call["command"])
        env = call["env"]
        self.assertIsInstance(env, dict)
        assert isinstance(env, dict)
        self.assertEqual(env["VEASEL_MODEL_PROVIDER"], "openai")
        self.assertEqual(env["VEASEL_MODEL"], "gpt-test")
        self.assertEqual(env["VEASEL_MODEL_API_KEY"], "fixture-secret")
        self.assertNotIn("fixture-secret", command)
        self.assertIn('"$HOME/.local/bin/veasel" serve', command)
        self.assertIn("--autonomous", command)
        self.assertIn("--trace-file /logs/agent/trajectory.json", command)
        self.assertIn("/logs/agent/veasel-server.log", command)
        self.assertIn("trap 'kill", command)
        self.assertEqual(call["timeout_sec"], 1830)
        subprocess.run(["bash", "-n"], input=command, text=True, check=True)

    async def test_install_pins_release_and_verifies_archive_hash_before_extracting(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            agent = VeaselCode(
                logs_dir=Path(directory),
                model_name="openai/gpt-test",
                veasel_version="1.2.3",
            )
            environment = RecordingEnvironment()
            await agent.install(environment)

        command = str(environment.calls[-1]["command"])
        self.assertIn("glibc 2.35 or newer", command)
        self.assertIn("releases/download/v1.2.3/veasel-Linux.tar.gz", command)
        self.assertIn("SHA256SUMS", command)
        self.assertIn("hashlib.sha256", command)
        self.assertLess(command.index("hashlib.sha256"), command.index("tar -xzf"))
        self.assertIn("uname -m", command)
        self.assertNotIn("grep", command)
        subprocess.run(["bash", "-n"], input=command, text=True, check=True)

    def test_trajectory_validation_uses_harbors_atif_model(self) -> None:
        trajectory = {
            "schema_version": "ATIF-v1.8",
            "session_id": "fixture-session",
            "agent": {"name": "Veasel Code", "version": "1.2.3", "model_name": "gpt-test"},
            "steps": [
                {"step_id": 1, "source": "system", "message": "You are Veasel Code."},
                {"step_id": 2, "source": "user", "message": "Fix the fixture."},
                {"step_id": 3, "source": "agent", "message": "Done."},
            ],
        }
        with tempfile.TemporaryDirectory() as directory:
            trace_path = Path(directory) / "trajectory.json"
            trace_path.write_text(json.dumps(trajectory))
            self.assertEqual(validate_trace(trace_path)["schema_version"], "ATIF-v1.8")
            adapter = VeaselCode(logs_dir=Path(directory), veasel_version="1.2.3")
            converted = adapter.convert_trajectory(Path(directory))

        self.assertIsNotNone(converted)
        self.assertEqual(converted.agent.name, "Veasel Code")
        self.assertEqual(len(converted.steps), 3)


if __name__ == "__main__":
    unittest.main()
