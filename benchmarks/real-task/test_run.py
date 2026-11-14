import hashlib
import importlib.util
import argparse
import json
import os
import stat
import subprocess
import shutil
import sys
import tarfile
import tempfile
import threading
import unittest
from decimal import Decimal
from pathlib import Path
from unittest.mock import Mock
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("run.py")
if str(SCRIPT.parent) not in sys.path:
    sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("real_task_runner", SCRIPT)
runner = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(runner)


def make_isolation_wrapper(root: Path) -> tuple[Path, str]:
    wrapper = root / "operator-isolation-wrapper"
    wrapper.write_text('#!/bin/sh\n[ "$1" = "--" ] || exit 64\nshift\nexec "$@"\n')
    wrapper.chmod(0o700)
    return wrapper, hashlib.sha256(wrapper.read_bytes()).hexdigest()


class IsolationWrapperTests(unittest.TestCase):
    def test_wrapper_is_required_and_sha256_must_match(self):
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
            root = Path(temp_dir)
            wrapper, digest = make_isolation_wrapper(root)
            with self.assertRaisesRegex(ValueError, "required"):
                runner.validated_isolation_wrapper(argparse.Namespace())
            with self.assertRaisesRegex(ValueError, "does not match"):
                runner.validated_isolation_wrapper(argparse.Namespace(
                    isolation_wrapper=wrapper, isolation_wrapper_sha256="0" * 64,
                ))
            actual_path, actual_digest = runner.validated_isolation_wrapper(argparse.Namespace(
                isolation_wrapper=wrapper, isolation_wrapper_sha256=digest,
            ))
        self.assertEqual(actual_path, wrapper.resolve())
        self.assertEqual(actual_digest, digest)

    def test_agent_command_is_always_passed_through_wrapper(self):
        self.assertEqual(
            runner.wrapped_command(Path("/opt/benchmark/isolate"), ["/usr/bin/veasel", "run"]),
            ["/opt/benchmark/isolate", "--", "/usr/bin/veasel", "run"],
        )

    def test_remote_opencode_live_preflight_requires_every_isolation_component(self):
        case_path = SCRIPT.parent / "cases/website-173-muse-spark-v0795/case.json"
        case, _prompt, _digest = runner.load_case(case_path)
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
            root = Path(temp_dir)
            wrapper, wrapper_hash = make_isolation_wrapper(root)
            task_parent = runner.persistent_private_directory(root / "state" / "workspaces")
            task_root = task_parent / "veasel-real-task-test"
            task_root.mkdir(mode=0o700)
            self.addCleanup(lambda: shutil.rmtree(task_root, ignore_errors=True))
            data_dir = root / "state"
            expected_config = runner.configured_model
            configured = {
                "provider": case["model"]["provider"], "model": case["model"]["name"],
                "base_url": case["provider_config"]["base_url"],
                "max_output_tokens": case["model"]["output_tokens"], "api_key_saved": True,
            }

            def git_result(_workspace, *args):
                if args[:2] == ("remote", "get-url"):
                    return case["repository"]
                if args[:2] == ("rev-parse", "HEAD"):
                    return case["base_commit"]
                return ""

            def validate_task_root(value, _commit, _parent):
                if value is None:
                    raise ValueError("task clone was not supplied")
                return task_root

            common_patches = (
                patch.object(runner, "available_resources", return_value=(10 * runner.GIB, 0)),
                patch.object(runner, "git", side_effect=git_result),
                patch.object(runner, "configured_model", return_value=configured),
                patch.object(runner, "project_open_code_config_paths", return_value=[]),
                patch.object(runner, "managed_open_code_config_paths", return_value=[]),
                patch.object(runner.shutil, "which", return_value="/usr/bin/opencode"),
                patch.object(runner, "open_code_version", return_value=case["comparators"]["opencode_version"]),
                patch.object(runner, "validate_task_clone", side_effect=validate_task_root),
                patch.object(runner, "validated_bwrap", return_value=Path("/usr/bin/bwrap")),
                patch.object(runner.platform, "system", return_value="Linux"),
            )
            for mock_patch in common_patches:
                mock_patch.start()
            self.addCleanup(lambda: [mock_patch.stop() for mock_patch in reversed(common_patches)])
            with patch.object(runner, "install_opencode_shell_wrapper",
                              return_value=(runner.OPEN_CODE_SHELL_WRAPPER,
                                            runner.OPEN_CODE_SHELL_WRAPPER_SHA256)):
                complete = runner.preflight(
                    case_path, root, "unused", data_dir, "opencode", "opencode", "5", "/usr/bin/bwrap",
                    wrapper, wrapper_hash, task_root,
                )
            check = next(item for item in complete["checks"] if item["name"] == "responses_proxy_live_isolation")
            self.assertTrue(check["passed"], check)
            with patch.object(runner, "install_opencode_shell_wrapper",
                              return_value=(runner.OPEN_CODE_SHELL_WRAPPER,
                                            runner.OPEN_CODE_SHELL_WRAPPER_SHA256)):
                missing_root = runner.preflight(
                    case_path, root, "unused", data_dir, "opencode", "opencode", "5", "/usr/bin/bwrap",
                    wrapper, wrapper_hash, None,
                )
            failed = next(item for item in missing_root["checks"] if item["name"] == "responses_proxy_live_isolation")
            self.assertFalse(failed["passed"])

    def test_run_refuses_to_preflight_or_launch_without_wrapper(self):
        args = argparse.Namespace()
        with patch.object(runner, "preflight", side_effect=AssertionError("must fail before preflight")), \
             patch.object(runner.subprocess, "Popen", side_effect=AssertionError("must not launch")):
            self.assertEqual(runner.run_case(args), 2)


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
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
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
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
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
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
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
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
            trace = Path(temp_dir) / "trace.json"
            trace.write_text(json.dumps({"steps": [{"step_id": 1}], "final_metrics": {},
                                         "extra": {"token_usage": "unavailable"}}))
            usage = runner.provider_reported_usage("veasel", trace, Path(temp_dir) / "stdout.log")
        self.assertFalse(usage["reported"])
        self.assertIsNone(usage["input_tokens"])
        self.assertIsNone(usage["output_tokens"])

    def test_opencode_usage_sums_only_step_finish_events(self):
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
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
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
            stdout = Path(temp_dir) / "stdout.log"
            stdout.write_text(json.dumps({"type": "text", "part": {"text": "done"}}))
            usage = runner.provider_reported_usage("opencode", Path(temp_dir) / "trace.json", stdout)
        self.assertFalse(usage["reported"])
        self.assertEqual(usage["usage_event_count"], 0)
        self.assertIsNone(usage["input_tokens"])
        self.assertIsNone(usage["reported_agent_cost_usd"])


class RemoteCasePinTests(unittest.TestCase):
    def test_tampered_price_or_provider_budget_is_rejected_before_credential_access(self):
        source = SCRIPT.parent / "cases/website-173-muse-spark-v0795/case.json"
        original = json.loads(source.read_text())
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
            root = Path(temp_dir)
            prompt = source.parent / original["prompt_file"]
            (root / "prompt.md").write_text(prompt.read_text())
            case_path = root / "case.json"
            tampered = json.loads(json.dumps(original))
            tampered["cost_budget"]["input_usd_per_million_tokens"] = 0.0001
            tampered["cost_budget"]["max_model_requests"] = 8400
            case_path.write_text(json.dumps(tampered))
            with patch.object(runner, "configured_model",
                              side_effect=AssertionError("credential/profile access must not happen")):
                with self.assertRaisesRegex(ValueError, "allowlist"):
                    runner.preflight(case_path, root, "unused", root / "state", approved_spend_usd="5")

    def test_exact_reviewed_remote_case_matches_fixed_model_rate_and_budget_pins(self):
        path = SCRIPT.parent / "cases/website-173-muse-spark-v0795/case.json"
        case, _prompt, _digest = runner.load_case(path)
        self.assertEqual(runner.validate_remote_case_pin(path, case), runner.REMOTE_CASE_SHA256)


class PreflightTests(unittest.TestCase):
    def setUp(self) -> None:
        self.allow_synthetic_remote_cases = patch.object(runner, "validate_remote_case_pin", return_value=None)
        self.allow_synthetic_remote_cases.start()
        self.addCleanup(self.allow_synthetic_remote_cases.stop)

    def test_disposable_task_clone_preserves_tracked_and_untracked_candidate_content(self):
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
            root = Path(temp_dir)
            source = root / "source"
            source.mkdir()
            subprocess.run(["git", "init", "--quiet", str(source)], check=True)
            subprocess.run(["git", "-C", str(source), "config", "user.email", "fixture@example.test"], check=True)
            subprocess.run(["git", "-C", str(source), "config", "user.name", "Fixture"], check=True)
            tracked = source / "tracked.txt"
            tracked.write_text("baseline\n")
            subprocess.run(["git", "-C", str(source), "add", "tracked.txt"], check=True)
            subprocess.run(["git", "-C", str(source), "commit", "--quiet", "-m", "baseline"], check=True)
            base_commit = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
            attacker_home = root / "attacker-home"
            attacker_home.mkdir()
            sentinel = root / "global-filter-ran"
            global_config = attacker_home / ".gitconfig"
            global_config.write_text(
                '[filter "hostile"]\n'
                f'  smudge = sh -c "touch {sentinel}; cat"\n'
            )
            (source / ".gitattributes").write_text("filtered.txt filter=hostile\n")
            (source / "filtered.txt").write_text("filter payload\n")
            subprocess.run(["git", "-C", str(source), "add", ".gitattributes", "filtered.txt"], check=True)
            subprocess.run(["git", "-C", str(source), "commit", "--quiet", "-m", "filter fixture"], check=True)
            base_commit = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
            task_parent = runner.persistent_private_directory(root / "state" / "workspaces")
            with patch.dict(runner.os.environ, {"HOME": str(attacker_home), "GIT_CONFIG_GLOBAL": str(global_config)}):
                clone = runner.create_task_clone(source, base_commit, root / "private-git-home", task_parent)
            self.addCleanup(lambda: shutil.rmtree(clone, ignore_errors=True))
            self.assertFalse(sentinel.exists())
            self.assertEqual((clone / "filtered.txt").read_text(), "filter payload\n")
            self.assertNotEqual(clone.resolve(), source.resolve())
            self.assertEqual(clone.parent, task_parent)
            self.assertEqual((clone / "tracked.txt").stat().st_ino != tracked.stat().st_ino, True)

            (clone / "tracked.txt").write_text("candidate edit\n")
            untracked = clone / "new file.txt"
            untracked.write_text("new candidate content\n")
            artifacts = root / "artifacts"
            artifacts.mkdir(mode=0o700)
            result = runner.preserve_candidate_changes(clone, base_commit, artifacts)
            self.assertTrue(result["dirty"])
            self.assertIn(b"candidate edit", (artifacts / result["patch_artifact"]).read_bytes())
            with tarfile.open(artifacts / result["untracked_archive"]) as archive:
                self.assertEqual(archive.extractfile("new file.txt").read(), b"new candidate content\n")
            self.assertEqual((clone / "tracked.txt").read_text(), "candidate edit\n")

            # A later runner process can rediscover the task by its durable path;
            # its unintegrated candidate changes survive runner interruption.
            recovered = runner.validate_task_clone(clone, base_commit, task_parent)
            self.assertEqual(recovered, clone)
            self.assertEqual((recovered / "tracked.txt").read_text(), "candidate edit\n")
            self.assertTrue((recovered / "new file.txt").is_file())

    def test_persistent_workspace_parent_rejects_temporary_roots(self):
        for path in (Path("/tmp/veasel-real-task-state"), Path("/var/tmp/veasel-real-task-state")):
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, "outside /tmp"):
                runner.persistent_private_directory(path)

    def test_aggregate_ledger_imports_prior_spend_and_reserves_concurrently(self):
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
            data_dir = Path(temp_dir) / "state"
            initial, provenance = runner.aggregate_ledger_snapshot(data_dir)
            self.assertEqual(initial["authorized_total_usd"], "5.00")
            self.assertEqual(initial["settled_spend_usd"], "0.35444")
            self.assertEqual(initial["remaining_usd"], "4.64556")
            self.assertIn("Approximate", provenance)
            self.assertTrue(initial["prior_spend_is_approximate"] == "true")

            barrier = threading.Barrier(3)
            outcomes: list[tuple[str, str]] = []
            outcome_lock = threading.Lock()

            def reserve(run_id: str) -> None:
                barrier.wait()
                try:
                    runner.reserve_aggregate_run(data_dir, run_id, "fixture", Decimal("4"))
                    result = (run_id, "reserved")
                except RuntimeError:
                    result = (run_id, "rejected")
                with outcome_lock:
                    outcomes.append(result)

            workers = [threading.Thread(target=reserve, args=(f"run-{index}",)) for index in range(2)]
            for worker in workers:
                worker.start()
            barrier.wait()
            for worker in workers:
                worker.join(timeout=5)
            self.assertTrue(all(not worker.is_alive() for worker in workers))
            self.assertCountEqual([status for _run_id, status in outcomes], ["reserved", "rejected"])
            winner = next(run_id for run_id, status in outcomes if status == "reserved")
            held = runner.aggregate_ledger_snapshot(data_dir)[0]
            self.assertEqual(held["reserved_usd"], "4")
            self.assertEqual(held["remaining_usd"], "0.64556")

            settled = runner.settle_aggregate_run(data_dir, winner, Decimal("0.01"))
            self.assertEqual(settled["reserved_usd"], "0")
            self.assertEqual(settled["settled_spend_usd"], "0.36444")
            uncertain_id = "run-uncertain"
            runner.reserve_aggregate_run(data_dir, uncertain_id, "fixture", Decimal("0.1"))
            after_interrupt = runner.settle_aggregate_run(data_dir, uncertain_id, None)
            self.assertEqual(after_interrupt["reserved_usd"], "0.1")
            restarted = runner.aggregate_ledger_snapshot(data_dir)[0]
            self.assertEqual(restarted["reserved_usd"], "0.1")
            self.assertEqual(restarted["settled_spend_usd"], "0.36444")

    @staticmethod
    def configured_case(root: Path) -> Path:
        case_dir = root / "case"
        case_dir.mkdir()
        prompt = "Add a deterministic test for the requested behavior.\n"
        (case_dir / "prompt.md").write_text(prompt)
        case = {
            "schema": "veasel.real-task-case.v1",
            "id": "example/repo#1",
            "repository": "https://github.com/example/repo.git",
            "base_commit": "a" * 40,
            "prompt_file": "prompt.md",
            "prompt_sha256": hashlib.sha256(prompt.encode()).hexdigest(),
            "model": {"provider": "anthropic", "name": "claude-example", "context_tokens": 8192,
                      "output_tokens": 1024},
            "provider_config": {"mode": "veasel-profile", "provider": "anthropic",
                                "model": "claude-example", "base_url": "https://api.anthropic.com/v1",
                                "credential": "saved-profile"},
            "runtime": {},
            "permissions": {"tool_allowlist": ["read", "edit", "shell"]},
            "budgets": {"wall_seconds": 60, "minimum_available_memory_bytes": 0,
                        "minimum_free_swap_bytes": 0},
            "cost_budget": {"max_cost_usd": 5, "input_usd_per_million_tokens": 0.1,
                            "cached_input_usd_per_million_tokens": 0.002,
                            "output_usd_per_million_tokens": 0.2, "max_model_requests": 84},
            "oracle": "Independently inspect the resulting patch.",
        }
        case_path = case_dir / "case.json"
        case_path.write_text(json.dumps(case))
        return case_path

    def test_case_prompt_hash_is_pinned(self):
        case_path = SCRIPT.parent / "cases/website-173/case.json"
        case, _prompt, digest = runner.load_case(case_path)
        self.assertEqual(digest, case["prompt_sha256"])

    def test_muse_spark_0793_case_is_immutable_and_pins_the_released_binary(self):
        case_path = SCRIPT.parent / "cases/website-173-muse-spark-v0793/case.json"
        case, _prompt, digest = runner.load_case(case_path)
        self.assertEqual(digest, case["prompt_sha256"])
        self.assertEqual(case["runtime"]["veasel_version"], "Veasel Code 0.79.3-next.0")
        self.assertIn("Veasel 0.79.3", case["cost_budget"]["request_cap_basis"])
        self.assertEqual(
            case["runtime"]["veasel_binary_sha256"],
            "f9055a2ca22d0ed0f5f670b0499664f87c765a4ce6376bbe77a1f68c3242080b",
        )
        self.assertEqual(
            hashlib.sha256(case_path.read_bytes()).hexdigest(),
            "619e50221c8bbfb25a3680c458f4352578be536c87d6d3a7862f9638d5c04517",
        )

    def test_muse_spark_0795_case_pins_responses_comparator_and_proxy_route(self):
        case_path = SCRIPT.parent / "cases/website-173-muse-spark-v0795/case.json"
        case, _prompt, digest = runner.load_case(case_path)
        self.assertEqual(digest, case["prompt_sha256"])
        self.assertEqual(case["runtime"]["veasel_version"], "Veasel Code 0.79.5-next.0")
        self.assertEqual(case["comparators"]["opencode_version"], "opencode v2.2.7")
        config = runner.open_code_config(case)
        provider = config["providers"]["museproxy"]
        self.assertEqual(config["model"], "museproxy/muse-spark-1.3-contributor")
        self.assertEqual(provider["package"], "@opencode/ai/providers/openai-compatible/responses")
        self.assertEqual(provider["settings"]["baseURL"], "http://127.0.0.1:1/v1")
        self.assertEqual(provider["models"][case["model"]["name"]]["limit"]["context"], 8192)
        self.assertEqual(provider["models"][case["model"]["name"]]["limit"]["output"], 2048)
        self.assertNotIn("api_key", json.dumps(config).lower())
        budget = runner.responses_proxy_budget(case, "5")
        self.assertEqual(budget["upstream_attempt_limit"], 84)
        self.assertEqual(budget["max_request_body_bytes"], 32768)
        self.assertEqual(budget["max_input_tokens_per_attempt"], 8192)
        self.assertEqual(budget["enforced_run_cost_cap_usd"], "0.10321920")
        self.assertIn("context input ceiling", budget["cost_basis"])

    def test_non_ollama_profile_preflight_checks_model_endpoint_budget_and_saved_credential(self):
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
            case_path = self.configured_case(Path(temp_dir))
            with patch.object(runner, "configured_model", return_value={
                "provider": "anthropic", "model": "claude-example",
                "base_url": "https://api.anthropic.com/v1", "max_output_tokens": 2048,
                "api_key_saved": True,
            }):
                _case, _prompt, _digest = runner.load_case(case_path)
                actual, checks = runner.configured_provider_target(_case, Path(temp_dir) / "state")
        self.assertTrue(all(check["passed"] for check in checks), checks)
        self.assertEqual(actual["provider"], "anthropic")
        self.assertNotIn("api_key", actual)

    def test_non_ollama_profile_fails_closed_on_missing_or_mismatched_credentials(self):
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
            case_path = self.configured_case(Path(temp_dir))
            with patch.object(runner, "configured_model", return_value={
                "provider": "openai-compatible", "model": "other-model",
                "base_url": "https://api.anthropic.com/v1", "max_output_tokens": 0,
                "api_key_saved": False,
            }):
                case, _prompt, _digest = runner.load_case(case_path)
                _actual, checks = runner.configured_provider_target(case, Path(temp_dir) / "state")
        failed = {item["name"] for item in checks if not item["passed"]}
        self.assertEqual(failed, {"provider_model_selection", "provider_output_budget", "provider_credential_ready"})

    @patch.object(runner, "available_resources", return_value=(10 * runner.GIB, 0))
    @patch.object(runner, "git", side_effect=["https://github.com/example/repo.git", "a" * 40, ""] * 4)
    def test_non_ollama_preflight_does_not_probe_ollama_or_claim_live_model_readiness(self, _git, _resources):
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
            case_path = self.configured_case(Path(temp_dir))
            with patch.object(runner, "configured_model", return_value={
                "provider": "anthropic", "model": "claude-example",
                "base_url": "https://api.anthropic.com/v1", "max_output_tokens": 1024,
                "api_key_saved": True,
            }), patch.object(runner, "model_digest", side_effect=AssertionError("must not probe Ollama")):
                result = runner.preflight(case_path, Path(temp_dir), "http://127.0.0.1:11435",
                                          Path(temp_dir) / "state", approved_spend_usd="5")
        self.assertTrue(result["passed"], result["checks"])
        readiness = next(item for item in result["checks"] if item["name"] == "provider_live_readiness")
        self.assertEqual(readiness["actual"], "not_probed")
        self.assertLess(Decimal(result["cost_budget"]["conservative_max_cost_usd"]), Decimal("5"))

    def test_configured_provider_preflight_fails_without_budget_authorization_or_when_bound_exceeds_ceiling(self):
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
            case_path = self.configured_case(Path(temp_dir))
            case, _prompt, _digest = runner.load_case(case_path)
            report, checks = runner.provider_cost_bound(case, "0")
            self.assertFalse(checks[0]["passed"])
            self.assertEqual(report["approved_spend_usd"], "0")
            report, checks = runner.provider_cost_bound(case, "0.01")
            self.assertFalse(checks[0]["passed"])
            self.assertGreater(Decimal(report["conservative_max_cost_usd"]), Decimal("0.01"))
            case["cost_budget"]["max_model_requests"] = 1
            report, checks = runner.provider_cost_bound(case, "5")
            self.assertFalse(checks[0]["passed"])
            self.assertNotEqual(report["max_model_requests"], report["pinned_runtime_max_model_requests"])

    def test_configured_provider_bound_includes_terminal_tool_budget_summary(self):
        case = {
            "model": {"context_tokens": 8192, "output_tokens": 2048},
            "cost_budget": {
                "max_cost_usd": 0.11,
                "input_usd_per_million_tokens": 0.1,
                "output_usd_per_million_tokens": 0.2,
                "max_model_requests": 84,
            },
        }
        report, checks = runner.provider_cost_bound(case, "5")
        self.assertTrue(checks[0]["passed"], checks)
        self.assertEqual(report["pinned_runtime_max_model_requests"], 84)
        self.assertEqual(report["conservative_max_cost_usd"], "0.10321920")
        case["cost_budget"]["max_cost_usd"] = 0.10
        _report, checks = runner.provider_cost_bound(case, "5")
        self.assertFalse(checks[0]["passed"])

    def test_reported_provider_cost_uses_pinned_rates_and_cached_input(self):
        case = {
            "cost_budget": {
                "input_usd_per_million_tokens": 0.1,
                "cached_input_usd_per_million_tokens": 0.002,
                "output_usd_per_million_tokens": 0.2,
            },
        }
        estimate = runner.estimate_provider_cost(case, {
            "input_tokens": 1000, "cache_read_tokens": 400, "output_tokens": 100,
        })
        self.assertEqual(estimate, "0.00008080")

    @patch.object(runner, "available_resources", return_value=(10 * runner.GIB, 0))
    @patch.object(runner, "git", side_effect=[
        "https://origin-user:origin-token@github.com/example/repo.git", "a" * 40, "",
    ])
    def test_preflight_never_serializes_repository_url_credentials(self, _git, _resources):
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
            root = Path(temp_dir)
            case_path = self.configured_case(root)
            case = json.loads(case_path.read_text())
            case["repository"] = "https://case-user:case-token@github.com/example/repo.git"
            case_path.write_text(json.dumps(case))
            with patch.object(runner, "configured_model", return_value={
                "provider": "anthropic", "model": "claude-example",
                "base_url": "https://api.anthropic.com/v1", "max_output_tokens": 1024,
                "api_key_saved": True,
            }):
                result = runner.preflight(case_path, root, "unused", root / "state", approved_spend_usd="5")
        self.assertTrue(result["passed"], result["checks"])
        serialized = json.dumps(result)
        for sentinel in ("origin-user", "origin-token", "case-user", "case-token"):
            self.assertNotIn(sentinel, serialized)
        repository_check = next(item for item in result["checks"] if item["name"] == "repository")
        self.assertEqual(repository_check["actual"], "matched")
        self.assertEqual(repository_check["required"], "pinned repository identity")

    @patch.object(runner, "available_resources", return_value=(10 * runner.GIB, 0))
    @patch.object(runner, "git", side_effect=[
        "https://github.com/example/repo.git?access_token=remote-secret", "a" * 40, "",
    ])
    def test_preflight_rejects_and_redacts_repository_url_query_secrets(self, _git, _resources):
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
            root = Path(temp_dir)
            case_path = self.configured_case(root)
            case = json.loads(case_path.read_text())
            case["repository"] = "https://github.com/example/repo.git?access_token=case-secret"
            case_path.write_text(json.dumps(case))
            with patch.object(runner, "configured_model", return_value={
                "provider": "anthropic", "model": "claude-example",
                "base_url": "https://api.anthropic.com/v1", "max_output_tokens": 1024,
                "api_key_saved": True,
            }):
                result = runner.preflight(case_path, root, "unused", root / "state")
        self.assertFalse(result["passed"])
        serialized = json.dumps(result)
        self.assertNotIn("remote-secret", serialized)
        self.assertNotIn("case-secret", serialized)

    @patch.object(runner, "available_resources", return_value=(10 * runner.GIB, 0))
    @patch.object(runner, "git", side_effect=["https://github.com/example/repo.git", "a" * 40, ""] * 4)
    def test_non_ollama_preflight_never_serializes_endpoint_secrets(self, _git, _resources):
        endpoint_cases = [
            ("https://userinfo-secret@example.invalid/v1", False),
            ("https://example.invalid/v1?token=query-secret", False),
            ("https://example.invalid/v1#fragment-secret", False),
            ("https://example.invalid/secret-path-token/v1", True),
        ]
        for endpoint, expected_pass in endpoint_cases:
            with self.subTest(endpoint_kind=endpoint.split(":", 1)[0]), tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
                case_path = self.configured_case(Path(temp_dir))
                case = json.loads(case_path.read_text())
                case["provider_config"]["base_url"] = endpoint
                case_path.write_text(json.dumps(case))
                with patch.object(runner, "configured_model", return_value={
                    "provider": "anthropic", "model": "claude-example", "base_url": endpoint,
                    "max_output_tokens": 1024, "api_key_saved": True,
                }):
                    result = runner.preflight(case_path, Path(temp_dir), "http://127.0.0.1:11435",
                                              Path(temp_dir) / "state", approved_spend_usd="5")
                serialized = json.dumps(result)
                self.assertEqual(result["passed"], expected_pass)
                for sentinel in ("userinfo-secret", "query-secret", "fragment-secret", "secret-path-token"):
                    self.assertNotIn(sentinel, serialized)

    @patch.object(runner, "available_resources", return_value=(10 * runner.GIB, 0))
    @patch.object(runner, "git", side_effect=["https://github.com/example/repo.git", "a" * 40, ""])
    @patch.object(runner, "configured_model", side_effect=OSError("profile unreadable"))
    @patch.object(runner, "model_digest", return_value="pinned-digest")
    def test_ollama_profile_read_error_does_not_serialize_expected_endpoint(self, _digest, _config, _git, _resources):
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
            case_path = self.configured_case(Path(temp_dir))
            case = json.loads(case_path.read_text())
            case["model"].update({"provider": "ollama", "name": "qwen3:8b", "digest": "pinned-digest"})
            case["provider_config"] = {
                "provider": "ollama", "model": "qwen3:8b",
                "base_url": "http://127.0.0.1:11435/secret-path-token/v1",
                "max_output_tokens": 1024, "api_key_saved": False,
            }
            case_path.write_text(json.dumps(case))
            result = runner.preflight(case_path, Path(temp_dir),
                                      "http://127.0.0.1:11435/secret-path-token", Path(temp_dir) / "state")
        serialized = json.dumps(result)
        self.assertFalse(result["passed"])
        self.assertNotIn("secret-path-token", serialized)
        config_check = next(item for item in result["checks"] if item["name"] == "veasel_model_config")
        self.assertNotIn("base_url", json.dumps(config_check))

    def test_provider_config_report_filters_field_types_and_enums(self):
        case = {"provider_config": {
            "mode": ["veasel-profile"], "provider": ["anthropic"],
            "model": "https://model-secret.invalid/id", "base_url": "https://url-secret.invalid/?token=x",
            "credential": ["saved-profile"], "max_output_tokens": True, "api_key_saved": "true",
        }}
        self.assertEqual(runner.safe_provider_config_report(case), {})

    @patch.object(runner, "preflight", return_value={"passed": True, "checks": []})
    @patch.object(runner.shutil, "which", return_value="/usr/bin/veasel")
    @patch.object(runner.subprocess, "check_output", return_value="veasel test")
    @patch.object(runner, "provider_reported_usage", return_value={"reported": False})
    def test_attempt_report_projects_provider_config_without_endpoint_secrets(self, _usage, _version, _which, _preflight):
        endpoint_cases = [
            "https://userinfo-secret@example.invalid/v1",
            "https://example.invalid/v1?token=query-secret",
            "https://example.invalid/v1#fragment-secret",
            "https://example.invalid/secret-path-token/v1",
        ]
        for endpoint in endpoint_cases:
            with self.subTest(endpoint_kind=endpoint.split(":", 1)[0]), tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
                root = Path(temp_dir)
                case_path = self.configured_case(root)
                case = json.loads(case_path.read_text())
                case["provider_config"]["base_url"] = endpoint
                case_path.write_text(json.dumps(case))
                workspace = root / "workspace"
                workspace.mkdir()
                artifacts = root / "artifacts"
                data_dir = root / "state"
                data_dir.mkdir()
                wrapper, wrapper_sha256 = make_isolation_wrapper(root)
                (data_dir / "model-settings.json").write_text(json.dumps({
                    "active_provider": "anthropic",
                    "profiles": {"anthropic": {
                        "model": "claude-example", "base_url": endpoint,
                        "max_output_tokens": 1024, "api_key": "private-provider-key",
                    }},
                }))
                process = Mock()
                process.poll.return_value = 0
                process.wait.return_value = 0
                args = argparse.Namespace(
                    case=case_path, workspace=workspace, data_dir=data_dir, ollama_url="unused",
                    agent="veasel", veasel="veasel", opencode="opencode", artifacts=artifacts,
                    isolation_wrapper=wrapper, isolation_wrapper_sha256=wrapper_sha256,
                    approved_spend_usd="5",
                )
                with (patch.object(runner, "create_task_clone", return_value=workspace),
                      patch.object(runner, "preserve_candidate_changes", return_value={"dirty": False}),
                      patch.object(runner, "validated_bwrap", return_value=Path("/usr/bin/bwrap")),
                      patch.object(runner.subprocess, "Popen", return_value=process) as popen):
                    self.assertEqual(runner.run_case(args), 0)
                launched_command = popen.call_args.args[0]
                self.assertEqual(launched_command[:2], [str(wrapper.resolve()), "--"])
                self.assertNotIn("private-provider-key", launched_command)
                launched_env = popen.call_args.kwargs["env"]
                self.assertEqual(launched_env["VEASEL_MODEL_API_KEY"], "private-provider-key")
                self.assertNotIn("private-provider-key", (data_dir / "model-settings.json").read_text())
                report_text = (artifacts / "attempt.json").read_text()
                report = json.loads(report_text)
                self.assertNotIn("base_url", report["provider_config"])
                self.assertEqual(report["isolation"]["wrapper_sha256"], wrapper_sha256)
                self.assertEqual(report["case_sha256"], hashlib.sha256(case_path.read_bytes()).hexdigest())
                for sentinel in ("userinfo-secret", "query-secret", "fragment-secret", "secret-path-token"):
                    self.assertNotIn(sentinel, report_text)

    def test_restricted_environment_drops_provider_key(self):
        env = runner.restricted_environment({
            "PATH": "/usr/bin", "VEASEL_MODEL_API_KEY": "must-not-reach-tools",
            "ANTHROPIC_API_KEY": "must-not-reach-tools-either", "LANG": "C.UTF-8",
        })
        self.assertEqual(env, {"PATH": "/usr/bin", "LANG": "C.UTF-8"})

    def test_config_projection_never_returns_saved_api_key(self):
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
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

    def test_config_projection_requires_nonblank_string_api_key(self):
        for api_key in ("   ", 123, ["present"]):
            with self.subTest(api_key_type=type(api_key).__name__):
                with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
                    settings_path = Path(temp_dir) / "model-settings.json"
                    settings_path.write_text(json.dumps({
                        "active_provider": "anthropic",
                        "profiles": {"anthropic": {"api_key": api_key}},
                    }))
                    config = runner.configured_model(Path(temp_dir))
                self.assertFalse(config["api_key_saved"])

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
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
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
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
            root = Path(temp_dir)
            workspace = root / "workspace"
            workspace.mkdir()
            artifacts = root / "artifacts"
            data_dir = root / "state"
            wrapper, wrapper_sha256 = make_isolation_wrapper(root)
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
                isolation_wrapper=wrapper,
                isolation_wrapper_sha256=wrapper_sha256,
                approved_spend_usd="0",
            )
            with patch.dict(runner.os.environ, {"ANTHROPIC_API_KEY": "test-secret"}):
                with (patch.object(runner, "create_task_clone", return_value=workspace),
                      patch.object(runner, "preserve_candidate_changes", return_value={"dirty": False}),
                      patch.object(runner.subprocess, "Popen", return_value=process) as popen):
                    self.assertEqual(runner.run_case(args), 0)
            launched_command = popen.call_args.args[0]
            launched_env = popen.call_args.kwargs["env"]
            self.assertEqual(launched_command[:2], [str(wrapper.resolve()), "--"])
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
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
            root = Path(temp_dir)
            workspace = root / "workspace"
            workspace.mkdir()
            artifacts = root / "artifacts"
            wrapper, wrapper_sha256 = make_isolation_wrapper(root)
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
                isolation_wrapper=wrapper,
                isolation_wrapper_sha256=wrapper_sha256,
                approved_spend_usd="0",
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
                patch.object(runner, "validated_bwrap", return_value=Path("/usr/bin/bwrap")),
                patch.object(runner.time, "sleep"),
                patch.object(runner, "create_task_clone", return_value=workspace),
                patch.object(runner, "preserve_candidate_changes", return_value={"dirty": False}),
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

    def test_runner_resource_exception_stops_process_group_and_writes_recovery_report(self):
        case_path = SCRIPT.parent / "cases/website-173/case.json"
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
            root = Path(temp_dir)
            workspace = root / "workspace"
            workspace.mkdir()
            artifacts = root / "artifacts"
            data_dir = root / "state"
            wrapper, wrapper_sha256 = make_isolation_wrapper(root)
            process = Mock()
            process.pid = 400123
            process.poll.return_value = None
            args = argparse.Namespace(
                case=case_path, workspace=workspace, data_dir=data_dir,
                ollama_url="http://127.0.0.1:11435", agent="opencode", opencode="opencode",
                veasel="veasel", artifacts=artifacts, isolation_wrapper=wrapper,
                isolation_wrapper_sha256=wrapper_sha256, approved_spend_usd="0",
            )
            with (
                patch.object(runner, "preflight", return_value={"passed": True, "checks": []}),
                patch.object(runner, "create_task_clone", return_value=workspace),
                patch.object(runner, "preserve_candidate_changes", return_value={"dirty": True,
                                                                                  "task_clone": str(workspace)}) as preserve,
                patch.object(runner, "provider_reported_usage", return_value={"reported": False}),
                patch.object(runner.shutil, "which", return_value="/usr/bin/opencode"),
                patch.object(runner, "open_code_version", return_value="opencode v2.2.7"),
                patch.object(runner, "validated_bwrap", return_value=Path("/usr/bin/bwrap")),
                patch.object(runner.platform, "platform", return_value="Linux-test"),
                patch.object(runner.platform, "machine", return_value="x86_64"),
                patch.object(runner.platform, "processor", return_value="test-cpu"),
                patch.object(runner, "available_resources", side_effect=RuntimeError("fixture sampler failed")),
                patch.object(runner, "terminate_process_group", return_value=True) as terminate,
                patch.object(runner.subprocess, "Popen", return_value=process),
            ):
                self.assertEqual(runner.run_case(args), 1)
            terminate.assert_called_once_with(process)
            preserve.assert_called_once()
            report = json.loads((artifacts / "attempt.json").read_text())
        self.assertEqual(report["outcome"], "runner_error")
        self.assertEqual(report["runner_error_type"], "RuntimeError")
        self.assertTrue(report["agent_process_group_terminated"])
        self.assertFalse(report["agent_process_group_orphaned"])
        self.assertTrue(report["artifacts"]["candidate"]["dirty"])

    def test_orphaned_resource_abort_uses_bounded_wait_and_writes_report(self):
        case_path = SCRIPT.parent / "cases/website-173/case.json"
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
            root = Path(temp_dir)
            workspace = root / "workspace"
            workspace.mkdir()
            artifacts = root / "artifacts"
            wrapper, wrapper_sha256 = make_isolation_wrapper(root)
            process = Mock()
            process.pid = 400124
            process.poll.return_value = None
            process.wait.side_effect = subprocess.TimeoutExpired(["agent"], 2.0)
            args = argparse.Namespace(
                case=case_path, workspace=workspace, data_dir=root / "state",
                ollama_url="http://127.0.0.1:11435", agent="opencode", opencode="opencode",
                veasel="veasel", artifacts=artifacts, isolation_wrapper=wrapper,
                isolation_wrapper_sha256=wrapper_sha256, approved_spend_usd="0",
            )
            with (
                patch.object(runner, "preflight", return_value={"passed": True, "checks": []}),
                patch.object(runner, "create_task_clone", return_value=workspace),
                patch.object(runner, "preserve_candidate_changes", return_value={"dirty": True}) as preserve,
                patch.object(runner, "provider_reported_usage", return_value={"reported": False}),
                patch.object(runner.shutil, "which", return_value="/usr/bin/opencode"),
                patch.object(runner, "open_code_version", return_value="opencode v2.2.7"),
                patch.object(runner, "validated_bwrap", return_value=Path("/usr/bin/bwrap")),
                patch.object(runner.platform, "platform", return_value="Linux-test"),
                patch.object(runner.platform, "machine", return_value="x86_64"),
                patch.object(runner.platform, "processor", return_value="test-cpu"),
                patch.object(runner, "available_resources", return_value=(1, 0)),
                patch.object(runner, "process_tree_resources", return_value=None),
                patch.object(runner, "gpu_memory_used_mib", return_value=None),
                patch.object(runner, "terminate_process_group", return_value=False) as terminate,
                patch.object(runner.subprocess, "Popen", return_value=process),
            ):
                self.assertEqual(runner.run_case(args), 1)
            terminate.assert_called_once_with(process)
            preserve.assert_called_once()
            report = json.loads((artifacts / "attempt.json").read_text())
            self.assertEqual(report["outcome"], "resource_aborted_orphaned")
            self.assertIsNone(report["runner_error_type"])
            process.wait.assert_called_once_with(timeout=2.0)
        self.assertEqual(report["outcome"], "resource_aborted_orphaned")
        self.assertEqual(report["return_code"], 124)
        self.assertFalse(report["agent_process_group_terminated"])
        self.assertTrue(report["agent_process_group_orphaned"])
        self.assertTrue(report["artifacts"]["candidate"]["dirty"])

    def _run_proxy_close_failure_case(self, close_exception):
        case_path = SCRIPT.parent / "cases/website-173-muse-spark-v0795/case.json"
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
            root = Path(temp_dir)
            workspace = root / "workspace"
            workspace.mkdir()
            artifacts = root / "artifacts"
            wrapper, wrapper_sha256 = make_isolation_wrapper(root)
            data_dir = root / "state"
            process = Mock()
            process.pid = 400125
            process.poll.return_value = 0
            process.wait.return_value = 0
            proxy = Mock()
            proxy.start.return_value = "http://127.0.0.1:43210/v1"
            proxy.close.side_effect = close_exception
            proxy.metrics.return_value = {
                "uncertain_responses": 0, "over_budget_responses": 0,
                "generation_cost_in_flight": 0, "generation_cost_reserved_usd": "0.00000000",
                "generation_cost_settled_usd": "0.00000000",
            }
            args = argparse.Namespace(
                case=case_path, workspace=workspace, data_dir=data_dir,
                ollama_url="http://127.0.0.1:11435", agent="opencode", opencode="opencode",
                veasel="veasel", artifacts=artifacts, isolation_wrapper=wrapper,
                isolation_wrapper_sha256=wrapper_sha256, approved_spend_usd="5",
            )
            with (
                patch.object(runner, "preflight", return_value={"passed": True, "checks": []}),
                patch.object(runner, "create_task_clone", return_value=workspace),
                patch.object(runner, "preserve_candidate_changes", return_value={"dirty": True}) as preserve,
                patch.object(runner, "provider_reported_usage", return_value={"reported": False}),
                patch.object(runner, "private_profile_key", return_value="fixture-secret"),
                patch.object(runner, "remove_profile_key_from_disk"),
                patch.object(runner, "responses_proxy_budget", return_value={
                    "upstream_attempt_limit": 84, "max_request_body_bytes": 32768,
                    "enforced_run_cost_cap_usd": "0.1",
                }),
                patch.object(runner, "BudgetProxy", return_value=proxy),
                patch.object(runner, "install_opencode_shell_wrapper", return_value=(root / "shell", "fixture-hash")),
                patch.object(runner, "prepare_open_code_config", return_value=root / "opencode.json"),
                patch.object(runner, "validated_bwrap", return_value=Path("/usr/bin/bwrap")),
                patch.object(runner, "build_command", return_value=["/usr/bin/opencode", "run"]),
                patch.object(runner.shutil, "which", return_value="/usr/bin/opencode"),
                patch.object(runner, "open_code_version", return_value="opencode v2.2.7"),
                patch.object(runner, "binary_sha256", return_value="fixture-binary-hash"),
                patch.object(runner.platform, "platform", return_value="Linux-test"),
                patch.object(runner.platform, "machine", return_value="x86_64"),
                patch.object(runner.platform, "processor", return_value="test-cpu"),
                patch.object(runner.subprocess, "Popen", return_value=process),
            ):
                self.assertEqual(runner.run_case(args), 1)
            proxy.close.assert_called_once_with()
            preserve.assert_called_once()
            report = json.loads((artifacts / "attempt.json").read_text())
        return report

    def test_proxy_close_error_still_preserves_candidate_and_writes_report(self):
        report = self._run_proxy_close_failure_case(RuntimeError("fixture close failure"))
        self.assertEqual(report["outcome"], "proxy_close_error")
        self.assertEqual(report["proxy_close_error_type"], "RuntimeError")
        self.assertTrue(report["artifacts"]["candidate"]["dirty"])
        self.assertEqual(report["aggregate_spend"]["status"], "reserved_uncertain")

    def test_second_ctrl_c_during_proxy_close_still_writes_recovery_report(self):
        report = self._run_proxy_close_failure_case(KeyboardInterrupt())
        self.assertEqual(report["outcome"], "proxy_close_interrupted")
        self.assertEqual(report["proxy_close_error_type"], "KeyboardInterrupt")
        self.assertTrue(report["artifacts"]["candidate"]["dirty"])
        self.assertEqual(report["aggregate_spend"]["status"], "reserved_uncertain")

    @unittest.skipUnless(sys.platform.startswith("linux"), "process group integration test requires Linux")
    def test_terminate_process_group_stops_agent_and_descendant(self):
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
            child_pid_file = Path(temp_dir) / "child.pid"
            parent_script = (
                "import signal, subprocess, sys, time\n"
                f"child = subprocess.Popen([sys.executable, '-c', \"import os,time; open({str(child_pid_file)!r}, 'w').write(str(os.getpid())); time.sleep(60)\"])\n"
                "def stop(_sig, _frame):\n"
                "    try: child.wait(timeout=2)\n"
                "    except subprocess.TimeoutExpired: child.kill(); child.wait()\n"
                "    raise SystemExit(0)\n"
                "signal.signal(signal.SIGINT, stop)\n"
                "time.sleep(60)\n"
            )
            process = subprocess.Popen(
                [sys.executable, "-c", parent_script],
                start_new_session=True,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            try:
                for _ in range(100):
                    if child_pid_file.exists():
                        break
                    threading.Event().wait(0.02)
                self.assertTrue(child_pid_file.exists(), "agent descendant did not start")
                child_pid = int(child_pid_file.read_text())
                self.assertTrue(runner.terminate_process_group(process, grace_seconds=1.0))
                self.assertIsNotNone(process.poll())
                with self.assertRaises(ProcessLookupError):
                    os.kill(child_pid, 0)
            finally:
                if process.poll() is None:
                    runner.terminate_process_group(process, grace_seconds=0.1)

    @patch.object(runner, "validated_bwrap", return_value=Path("/usr/bin/bwrap"))
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
    def test_opencode_preflight_uses_same_pinned_case(self, _resources, _managed, _project, _version, _gpu_info, _placement, _ollama, _model, _git, _which, _bwrap):
        case_path = SCRIPT.parent / "cases/website-173/case.json"
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
            result = runner.preflight(case_path, Path("/tmp/clean-checkout"), "http://127.0.0.1:11435",
                                      Path(temp_dir) / "opencode-state", "opencode", "opencode")
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
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
            result = runner.preflight(case_path, Path("/tmp/clean-checkout"), "http://127.0.0.1:11435", Path(temp_dir) / "isolated-veasel")
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
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
            result = runner.preflight(case_path, Path("/tmp/clean-checkout"), "http://127.0.0.1:11435", Path(temp_dir) / "isolated-veasel")
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
        with tempfile.TemporaryDirectory(dir=Path.home()) as temp_dir:
            result = runner.preflight(case_path, Path("/tmp/clean-checkout"), "http://127.0.0.1:11434", Path(temp_dir) / "isolated-veasel")
        failed = {check["name"] for check in result["checks"] if not check["passed"]}
        self.assertEqual(failed, {"ollama_endpoint", "model_digest", "ollama_model_gpu_placement"})


if __name__ == "__main__":
    unittest.main()
