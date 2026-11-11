import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("run.py")
SPEC = importlib.util.spec_from_file_location("real_task_runner", SCRIPT)
runner = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(runner)


class PreflightTests(unittest.TestCase):
    def test_case_prompt_hash_is_pinned(self):
        case_path = SCRIPT.parent / "cases/website-173/case.json"
        case, _prompt, digest = runner.load_case(case_path)
        self.assertEqual(digest, case["prompt_sha256"])

    def test_config_projection_never_returns_saved_api_key(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            settings_path = Path(temp_dir) / "model-settings.json"
            settings_path.write_text(json.dumps({
                "active_provider": "ollama",
                "profiles": {"ollama": {
                    "model": "qwen3:8b",
                    "base_url": "http://127.0.0.1:11435/v1",
                    "max_output_tokens": 2048,
                    "api_key": "must-not-leak",
                }},
            }))
            config = runner.configured_model(Path(temp_dir))
        self.assertTrue(config["api_key_saved"])
        self.assertNotIn("must-not-leak", repr(config))

    @patch.object(runner, "git", side_effect=["https://github.com/veasel-labs/website.git", "184c7d86911d4a760ec89c6ddc9097682e65da44", ""])
    @patch.object(runner, "model_digest", return_value="500a1f067a9f782620b40bee6f7b0c89e17ae61f686b92c24933e4ca4b2b8b41")
    @patch.object(runner, "ollama_version", return_value="0.40.15")
    @patch.object(runner, "gpu_info", return_value={"name": "NVIDIA GeForce RTX 3060", "memory_mib": 12288})
    @patch.object(runner, "configured_model", return_value={"provider": "ollama", "model": "qwen3:8b", "base_url": "http://127.0.0.1:11435/v1", "max_output_tokens": 2048, "api_key_saved": False})
    @patch.object(runner, "available_resources", return_value=(10 * runner.GIB, 3 * runner.GIB))
    def test_preflight_passes_only_when_pins_and_resources_match(self, _resources, _config, _gpu, _ollama, _model, _git):
        case_path = SCRIPT.parent / "cases/website-173/case.json"
        result = runner.preflight(case_path, Path("/tmp/clean-checkout"), "http://127.0.0.1:11435", Path("/tmp/isolated-veasel"))
        self.assertTrue(result["passed"])

    @patch.object(runner, "git", side_effect=["https://github.com/veasel-labs/website.git", "184c7d86911d4a760ec89c6ddc9097682e65da44", ""])
    @patch.object(runner, "model_digest", return_value="wrong-digest")
    @patch.object(runner, "ollama_version", return_value="0.40.15")
    @patch.object(runner, "gpu_info", return_value={"name": "NVIDIA GeForce RTX 3060", "memory_mib": 12288})
    @patch.object(runner, "configured_model", return_value={"provider": "ollama", "model": "qwen3:8b", "base_url": "http://127.0.0.1:11435/v1", "max_output_tokens": 2048, "api_key_saved": False})
    @patch.object(runner, "available_resources", return_value=(8 * runner.GIB, runner.GIB))
    def test_resource_or_model_mismatch_blocks_attempt(self, _resources, _config, _gpu, _ollama, _model, _git):
        case_path = SCRIPT.parent / "cases/website-173/case.json"
        result = runner.preflight(case_path, Path("/tmp/clean-checkout"), "http://127.0.0.1:11435", Path("/tmp/isolated-veasel"))
        failed = {check["name"] for check in result["checks"] if not check["passed"]}
        self.assertEqual(failed, {"model_digest", "available_memory", "free_swap"})


if __name__ == "__main__":
    unittest.main()
