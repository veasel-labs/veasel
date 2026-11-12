import importlib.util
import argparse
import json
import stat
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("run.py")
SPEC = importlib.util.spec_from_file_location("real_task_runner", SCRIPT)
runner = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(runner)


class ResourceSamplerTests(unittest.TestCase):
    @staticmethod
    def proc_stat(pid: int, parent_pid: int, user_ticks: int, system_ticks: int, rss_pages: int, command: str) -> str:
        fields = ["S", str(parent_pid)] + ["0"] * 20
        fields[11] = str(user_ticks)
        fields[12] = str(system_ticks)
        fields[21] = str(rss_pages)
        return f"{pid} ({command}) " + " ".join(fields)

    def test_parse_proc_stat_handles_command_with_spaces_and_parenthesis(self):
        stat = self.proc_stat(120, 5, 80, 20, 12, "agent (worker)")
        self.assertEqual(runner.parse_proc_stat(stat, 4096), (5, 100, 12 * 4096))

    def test_process_tree_resources_sums_root_and_descendants(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            proc_root = Path(temp_dir)
            processes = {
                100: self.proc_stat(100, 1, 20, 10, 100, "veasel"),
                101: self.proc_stat(101, 100, 40, 10, 200, "bwrap child"),
                200: self.proc_stat(200, 1, 500, 20, 900, "unrelated"),
            }
            for pid, stat in processes.items():
                process_dir = proc_root / str(pid)
                process_dir.mkdir()
                (process_dir / "stat").write_text(stat)
            metrics = runner.process_tree_resources(100, proc_root)
        self.assertIsNotNone(metrics)
        self.assertEqual(metrics["process_count"], 2)
        self.assertEqual(metrics["cpu_time_ms"], int(80 * 1000 / runner.os.sysconf("SC_CLK_TCK")))
        self.assertEqual(metrics["rss_bytes"], 300 * runner.os.sysconf("SC_PAGE_SIZE"))

    def test_process_tree_resources_returns_none_for_missing_root(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            self.assertIsNone(runner.process_tree_resources(99, Path(temp_dir)))

    @patch.object(runner.subprocess, "check_output", return_value="1400\n 1700\n")
    def test_gpu_memory_sampler_returns_one_value_per_device(self, check_output):
        self.assertEqual(runner.gpu_memory_used_mib(), [1400, 1700])
        check_output.assert_called_once_with(
            ["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
            text=True,
            timeout=2,
        )

    @patch.object(runner.subprocess, "check_output", side_effect=FileNotFoundError)
    def test_gpu_memory_sampler_is_optional_when_nvidia_smi_is_unavailable(self, _check_output):
        self.assertIsNone(runner.gpu_memory_used_mib())

    def test_resource_summary_reports_sampled_maxima_and_scope(self):
        summary = runner.resource_measurement_summary([
            {"agent_process_tree_rss_bytes": 100, "agent_process_tree_cpu_time_ms": 20,
             "sampling_overhead_ms": 5, "gpu_memory_used_mib": [4000]},
            {"agent_process_tree_rss_bytes": 300, "agent_process_tree_cpu_time_ms": 70,
             "sampling_overhead_ms": 9, "gpu_memory_used_mib": [5000]},
        ])
        self.assertEqual(summary["agent_process_tree_rss_sampled_max_bytes"], 300)
        self.assertEqual(summary["agent_process_tree_cpu_time_sampled_max_ms"], 70)
        self.assertEqual(summary["sampling_interval_target_seconds"], 1)
        self.assertEqual(summary["sampling_overhead_total_ms"], 14)
        self.assertEqual(summary["gpu_device_memory_used_sampled_max_mib"], [5000])
        self.assertIn("shared pages", summary["agent_memory_scope"])
        self.assertIn("device-wide", summary["gpu_memory_scope"])


class ProviderUsageTests(unittest.TestCase):
    def test_veasel_usage_reads_provider_reported_atif_metrics(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            trace = Path(temp_dir) / "trace.json"
            stdout = Path(temp_dir) / "stdout.log"
            trace.write_text(json.dumps({
                "steps": [{"step_id": 1}, {"step_id": 2}],
                "final_metrics": {
                    "total_prompt_tokens": 1200,
                    "total_completion_tokens": 48,
                    "reasoning_tokens": 5,
                    "cache_read_tokens": 700,
                    "cache_creation_tokens": 100,
                },
                "extra": {"token_usage": "reported"},
            }))
            usage = runner.provider_reported_usage("veasel", trace, stdout)
        self.assertTrue(usage["reported"])
        self.assertEqual(usage["source"], "veasel_atif_final_metrics")
        self.assertEqual(usage["trace_step_count"], 2)
        self.assertEqual(usage["input_tokens"], 1200)
        self.assertEqual(usage["output_tokens"], 48)
        self.assertEqual(usage["reasoning_tokens"], 5)
        self.assertEqual(usage["cache_read_tokens"], 700)
        self.assertEqual(usage["cache_write_tokens"], 100)

    def test_veasel_unreported_usage_is_not_recorded_as_zero(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            trace = Path(temp_dir) / "trace.json"
            trace.write_text(json.dumps({"steps": [{"step_id": 1}], "final_metrics": {},
                                         "extra": {"token_usage": "unavailable"}}))
            usage = runner.provider_reported_usage("veasel", trace, Path(temp_dir) / "stdout.log")
        self.assertFalse(usage["reported"])
        self.assertIsNone(usage["input_tokens"])
        self.assertIsNone(usage["output_tokens"])

    def test_opencode_usage_sums_only_step_finish_events(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            stdout = Path(temp_dir) / "stdout.log"
            stdout.write_text("\n".join([
                json.dumps({"type": "text", "part": {"text": "done"}}),
                json.dumps({"type": "step_finish", "part": {"tokens": {
                    "input": 500, "output": 20, "reasoning": 4,
                    "cache": {"read": 300, "write": 10},
                }, "cost": 0.003}}),
                json.dumps({"type": "step_finish", "part": {"tokens": {
                    "input": 600, "output": 30, "reasoning": 6,
                    "cache": {"read": 400, "write": 20},
                }, "cost": 0.004}}),
                "not json",
            ]))
            usage = runner.provider_reported_usage("opencode", Path(temp_dir) / "trace.json", stdout)
        self.assertTrue(usage["reported"])
        self.assertEqual(usage["source"], "opencode_json_step_finish_events")
        self.assertEqual(usage["usage_event_count"], 2)
        self.assertEqual(usage["input_tokens"], 1100)
        self.assertEqual(usage["output_tokens"], 50)
        self.assertEqual(usage["reasoning_tokens"], 10)
        self.assertEqual(usage["cache_read_tokens"], 700)
        self.assertEqual(usage["cache_write_tokens"], 30)
        self.assertAlmostEqual(usage["reported_agent_cost_usd"], 0.007)

    def test_missing_opencode_step_finish_keeps_usage_unavailable(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            stdout = Path(temp_dir) / "stdout.log"
            stdout.write_text(json.dumps({"type": "text", "part": {"text": "done"}}))
            usage = runner.provider_reported_usage("opencode", Path(temp_dir) / "trace.json", stdout)
        self.assertFalse(usage["reported"])
        self.assertEqual(usage["usage_event_count"], 0)
        self.assertIsNone(usage["input_tokens"])
        self.assertIsNone(usage["reported_agent_cost_usd"])


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

    def test_opencode_config_pins_endpoint_and_token_limits(self):
        case_path = SCRIPT.parent / "cases/website-173/case.json"
        case, _prompt, _digest = runner.load_case(case_path)
        config = runner.open_code_config(case)
        self.assertEqual(config["model"], "ollama/qwen3:8b")
        self.assertEqual(config["providers"]["ollama"]["settings"]["baseURL"], "http://127.0.0.1:11435/v1")
        self.assertEqual(config["providers"]["ollama"]["models"]["qwen3:8b"]["limit"], {"context": 4096, "output": 2048})
        permissions = config["agents"]["build"]["permissions"]
        self.assertEqual(permissions[0], {"action": "*", "resource": "*", "effect": "deny"})
        self.assertIn({"action": "shell", "resource": "*", "effect": "allow"}, permissions)
        self.assertIn({"action": "external_directory", "resource": "*", "effect": "deny"}, permissions)
        self.assertNotIn({"action": "webfetch", "resource": "*", "effect": "allow"}, permissions)

    def test_opencode_config_is_private_and_refuses_drift(self):
        case_path = SCRIPT.parent / "cases/website-173/case.json"
        case, _prompt, _digest = runner.load_case(case_path)
        with tempfile.TemporaryDirectory() as temp_dir:
            data_dir = Path(temp_dir) / "isolated-state"
            config_path = runner.prepare_open_code_config(case, data_dir)
            self.assertEqual(stat.S_IMODE(data_dir.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(config_path.stat().st_mode), 0o600)
            config_path.write_text("{}")
            with self.assertRaises(RuntimeError):
                runner.prepare_open_code_config(case, data_dir)

    def test_runner_environment_drops_provider_credentials_and_agent_overrides(self):
        environment = runner.restricted_environment({
            "PATH": "/usr/bin",
            "HOME": "/sandbox/home",
            "ANTHROPIC_API_KEY": "must-not-leak",
            "OPENAI_API_KEY": "must-not-leak",
            "VEASEL_DATA_DIR": "/host/veasel-state",
            "OPENCODE_CONFIG": "/host/opencode.json",
            "LANG": "C.UTF-8",
        })
        self.assertEqual(environment, {"PATH": "/usr/bin", "HOME": "/sandbox/home", "LANG": "C.UTF-8"})

    def test_open_code_command_uses_pinned_model_workspace_and_approval_mode(self):
        case_path = SCRIPT.parent / "cases/website-173/case.json"
        case, prompt_path, _digest = runner.load_case(case_path)
        command = runner.build_command("opencode", "/usr/bin/opencode", case, Path("/workspace/task"),
                                       prompt_path.read_text(), Path("/artifacts/trajectory.json"))
        self.assertEqual(command[:8], [
            "/usr/bin/opencode", "run", "--standalone", "--auto", "--model",
            "ollama/qwen3:8b", "--agent", "build",
        ])
        self.assertEqual(command[-3:], ["--format", "json", prompt_path.read_text()])
        self.assertNotIn("--dir", command)

    @patch.object(runner, "preflight", return_value={"passed": True, "checks": []})
    @patch.object(runner.shutil, "which", return_value="/usr/bin/opencode")
    @patch.object(runner.subprocess, "check_output", return_value="opencode v2.2.5")
    def test_opencode_launcher_records_private_unscored_attempt_without_model_call(self, _version, _which, _preflight):
        case_path = SCRIPT.parent / "cases/website-173/case.json"
        _case, _prompt, _digest = runner.load_case(case_path)
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            workspace = root / "workspace"
            workspace.mkdir()
            artifacts = root / "artifacts"
            data_dir = root / "state"
            process = Mock()
            process.poll.return_value = 0
            process.wait.return_value = 0
            args = argparse.Namespace(
                case=case_path,
                workspace=workspace,
                data_dir=data_dir,
                ollama_url="http://127.0.0.1:11435",
                agent="opencode",
                opencode="opencode",
                veasel="veasel",
                artifacts=artifacts,
                sandbox_confirmed=True,
            )
            with patch.dict(runner.os.environ, {"ANTHROPIC_API_KEY": "test-secret"}):
                with patch.object(runner.subprocess, "Popen", return_value=process) as popen:
                    self.assertEqual(runner.run_case(args), 0)
            launched_command = popen.call_args.args[0]
            launched_env = popen.call_args.kwargs["env"]
            self.assertIn("--standalone", launched_command)
            self.assertEqual(launched_env["OPENCODE_CONFIG"], str(data_dir / "benchmark-opencode.json"))
            self.assertNotIn("ANTHROPIC_API_KEY", launched_env)
            self.assertEqual(popen.call_args.kwargs["cwd"], workspace)
            report = json.loads((artifacts / "attempt.json").read_text())
            self.assertEqual(report["outcome"], "completed")
            self.assertEqual(report["score"], "unscored; externally verify the patch and task oracle")
            self.assertEqual(report["resource_measurements"]["sampling_interval_target_seconds"], 1)
            self.assertIsNone(report["resource_measurements"]["agent_process_tree_rss_sampled_max_bytes"])
            self.assertFalse(report["provider_usage"]["reported"])
            self.assertEqual(report["provider_usage"]["source"], "opencode_json_step_finish_events")

    def test_launcher_records_agent_and_gpu_resource_samples(self):
        case_path = SCRIPT.parent / "cases/website-173/case.json"
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            workspace = root / "workspace"
            workspace.mkdir()
            artifacts = root / "artifacts"
            process = Mock()
            process.poll.side_effect = [None, 0]
            process.wait.return_value = 0
            args = argparse.Namespace(
                case=case_path,
                workspace=workspace,
                data_dir=root / "state",
                ollama_url="http://127.0.0.1:11435",
                agent="opencode",
                opencode="opencode",
                veasel="veasel",
                artifacts=artifacts,
                sandbox_confirmed=True,
            )
            with (
                patch.object(runner, "preflight", return_value={"passed": True, "checks": []}),
                patch.object(runner.shutil, "which", return_value="/usr/bin/opencode"),
                patch.object(runner, "open_code_version", return_value="opencode v2.2.5"),
                patch.object(runner.platform, "platform", return_value="Linux-test"),
                patch.object(runner.platform, "machine", return_value="x86_64"),
                patch.object(runner.platform, "processor", return_value="test-cpu"),
                patch.object(runner.subprocess, "Popen", return_value=process),
                patch.object(runner, "available_resources", return_value=(8 * runner.GIB, 2 * runner.GIB)),
                patch.object(runner, "process_tree_resources", return_value={"process_count": 2, "cpu_time_ms": 42, "rss_bytes": 900}),
                patch.object(runner, "gpu_memory_used_mib", return_value=[6000]),
                patch.object(runner.time, "sleep"),
            ):
                self.assertEqual(runner.run_case(args), 0)
            report = json.loads((artifacts / "attempt.json").read_text())
        self.assertEqual(report["resource_samples"][0]["agent_process_tree_rss_bytes"], 900)
        self.assertEqual(report["resource_samples"][0]["agent_process_tree_cpu_time_ms"], 42)
        self.assertEqual(report["resource_samples"][0]["gpu_memory_used_mib"], [6000])
        self.assertIsInstance(report["resource_samples"][0]["sampling_overhead_ms"], int)
        measurements = report["resource_measurements"]
        self.assertEqual(measurements["agent_process_tree_rss_sampled_max_bytes"], 900)
        self.assertEqual(measurements["agent_process_tree_cpu_time_sampled_max_ms"], 42)
        self.assertEqual(measurements["gpu_device_memory_used_sampled_max_mib"], [6000])

    @patch.object(runner.shutil, "which", return_value="/usr/bin/opencode")
    @patch.object(runner, "git", side_effect=["https://github.com/veasel-labs/website.git", "184c7d86911d4a760ec89c6ddc9097682e65da44", ""])
    @patch.object(runner, "model_digest", return_value="500a1f067a9f782620b40bee6f7b0c89e17ae61f686b92c24933e4ca4b2b8b41")
    @patch.object(runner, "ollama_version", return_value="0.40.15")
    @patch.object(runner, "ollama_gpu_placement", return_value={"name": "qwen3:8b", "digest": "500a1f067a9f782620b40bee6f7b0c89e17ae61f686b92c24933e4ca4b2b8b41", "size_bytes": 5_054_440_406, "size_vram_bytes": 5_586_592_726, "context_length": 4096, "runner": "llamacpp"})
    @patch.object(runner, "gpu_info", return_value={"name": "NVIDIA GeForce RTX 3060", "memory_mib": 12288})
    @patch.object(runner, "open_code_version", return_value="opencode v2.2.5")
    @patch.object(runner, "project_open_code_config_paths", return_value=[])
    @patch.object(runner, "managed_open_code_config_paths", return_value=[])
    @patch.object(runner, "available_resources", return_value=(10 * runner.GIB, 3 * runner.GIB))
    def test_opencode_preflight_uses_same_pinned_case(self, _resources, _managed, _project, _version, _gpu_info, _placement, _ollama, _model, _git, _which):
        case_path = SCRIPT.parent / "cases/website-173/case.json"
        result = runner.preflight(case_path, Path("/tmp/clean-checkout"), "http://127.0.0.1:11435",
                                  Path("/tmp/opencode-state"), "opencode", "opencode")
        self.assertTrue(result["passed"], result["checks"])

    @patch.object(runner, "git", side_effect=["https://github.com/veasel-labs/website.git", "184c7d86911d4a760ec89c6ddc9097682e65da44", ""])
    @patch.object(runner, "model_digest", return_value="500a1f067a9f782620b40bee6f7b0c89e17ae61f686b92c24933e4ca4b2b8b41")
    @patch.object(runner, "ollama_version", return_value="0.40.15")
    @patch.object(runner, "ollama_gpu_placement", return_value={"name": "qwen3:8b", "digest": "500a1f067a9f782620b40bee6f7b0c89e17ae61f686b92c24933e4ca4b2b8b41", "size_bytes": 5_054_440_406, "size_vram_bytes": 5_586_592_726, "context_length": 4096, "runner": "llamacpp"})
    @patch.object(runner, "gpu_info", return_value={"name": "NVIDIA GeForce RTX 3060", "memory_mib": 12288})
    @patch.object(runner, "configured_model", return_value={"provider": "ollama", "model": "qwen3:8b", "base_url": "http://127.0.0.1:11435/v1", "max_output_tokens": 2048, "api_key_saved": False})
    @patch.object(runner, "available_resources", return_value=(10 * runner.GIB, 3 * runner.GIB))
    def test_preflight_passes_only_when_pins_and_resources_match(self, _resources, _config, _gpu_info, _placement, _ollama, _model, _git):
        case_path = SCRIPT.parent / "cases/website-173/case.json"
        result = runner.preflight(case_path, Path("/tmp/clean-checkout"), "http://127.0.0.1:11435", Path("/tmp/isolated-veasel"))
        self.assertTrue(result["passed"])

    @patch.object(runner, "git", side_effect=["https://github.com/veasel-labs/website.git", "184c7d86911d4a760ec89c6ddc9097682e65da44", ""])
    @patch.object(runner, "model_digest", return_value="500a1f067a9f782620b40bee6f7b0c89e17ae61f686b92c24933e4ca4b2b8b41")
    @patch.object(runner, "ollama_version", return_value="0.40.15")
    @patch.object(runner, "ollama_gpu_placement", return_value={"name": "qwen3:8b", "digest": "500a1f067a9f782620b40bee6f7b0c89e17ae61f686b92c24933e4ca4b2b8b41", "size_bytes": 5_054_440_406, "size_vram_bytes": 5_586_592_726, "context_length": 4096, "runner": "llamacpp"})
    @patch.object(runner, "gpu_info", return_value={"name": "NVIDIA GeForce RTX 3060", "memory_mib": 12288})
    @patch.object(runner, "configured_model", return_value={"provider": "ollama", "model": "qwen3:8b", "base_url": "http://127.0.0.1:11435/v1", "max_output_tokens": 2048, "api_key_saved": False})
    @patch.object(runner, "available_resources", return_value=(5 * runner.GIB, 0))
    def test_preflight_blocks_launch_without_observed_startup_headroom(self, _resources, _config, _gpu_info, _placement, _ollama, _model, _git):
        case_path = SCRIPT.parent / "cases/website-173/case.json"
        result = runner.preflight(case_path, Path("/tmp/clean-checkout"), "http://127.0.0.1:11435", Path("/tmp/isolated-veasel"))
        failed = {check["name"] for check in result["checks"] if not check["passed"]}
        self.assertEqual(failed, {"startup_memory_headroom"})
        startup_check = next(check for check in result["checks"] if check["name"] == "startup_memory_headroom")
        self.assertEqual(startup_check["required"], 6174015488)

    @patch.object(runner, "git", side_effect=["https://github.com/veasel-labs/website.git", "184c7d86911d4a760ec89c6ddc9097682e65da44", ""])
    @patch.object(runner, "model_digest", return_value="wrong-digest")
    @patch.object(runner, "ollama_version", return_value="0.40.15")
    @patch.object(runner, "ollama_gpu_placement", return_value={"name": "qwen3:8b", "digest": "wrong-digest", "size_bytes": 5_054_440_406, "size_vram_bytes": 0, "context_length": 4096, "runner": "llamacpp"})
    @patch.object(runner, "gpu_info", return_value={"name": "NVIDIA GeForce RTX 3060", "memory_mib": 12288})
    @patch.object(runner, "configured_model", return_value={"provider": "ollama", "model": "qwen3:8b", "base_url": "http://127.0.0.1:11435/v1", "max_output_tokens": 2048, "api_key_saved": False})
    @patch.object(runner, "available_resources", return_value=(8 * runner.GIB, runner.GIB))
    def test_resource_or_model_mismatch_blocks_attempt(self, _resources, _config, _gpu_info, _placement, _ollama, _model, _git):
        case_path = SCRIPT.parent / "cases/website-173/case.json"
        result = runner.preflight(case_path, Path("/tmp/clean-checkout"), "http://127.0.0.1:11434", Path("/tmp/isolated-veasel"))
        failed = {check["name"] for check in result["checks"] if not check["passed"]}
        self.assertEqual(failed, {"ollama_endpoint", "model_digest", "ollama_model_gpu_placement"})


if __name__ == "__main__":
    unittest.main()
