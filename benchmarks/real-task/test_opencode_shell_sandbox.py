"""Tests for the Linux-only shell boundary used by OpenCode v2.2.7."""

import json
import contextlib
import os
import platform
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


HERE = Path(__file__).resolve().parent
REPOSITORY_ROOT = HERE.parents[1]
LAUNCHER = HERE / "opencode-shell-sandbox.sh"
FIXTURE = HERE / "opencode-2.2.7-shell-config.fixture.json"
SECRET = "veasel-shell-boundary-secret-9d30"
SECRET_KEYS = (
    "OPENAI_API_KEY",
    "META_API_KEY",
    "PROXY_BEARER_TOKEN",
    "VEASEL_MODEL_API_KEY",
)
INVALID_ROOT_PROBE = shutil.which("true") or "/usr/bin/true"
HOST_FILESYSTEM_CANARY = Path("/etc/hostname")


@contextlib.contextmanager
def persistent_workspace():
    with tempfile.TemporaryDirectory(prefix=".veasel-shell-test-", dir=Path.home()) as temp:
        parent = Path(temp) / "workspaces"
        parent.mkdir(mode=0o700)
        root = parent / "veasel-real-task-test"
        root.mkdir(mode=0o700)
        yield parent, root


class OpenCode227CompatibilityTests(unittest.TestCase):
    def test_pinned_shell_config_and_shellselect_argv_contract(self):
        fixture = json.loads(FIXTURE.read_text())
        upstream = fixture["upstream"]
        self.assertEqual(upstream["tag"], "v2.2.7")
        self.assertEqual(upstream["commit"], "fedc6f208aa2bd54c1019227214568083f6380ad")
        self.assertEqual(
            set(upstream["source_sha256"]),
            {
                "packages/schema/src/config.ts",
                "packages/core/src/shell/select.ts",
                "packages/core/src/shell.ts",
            },
        )
        self.assertTrue(all(len(value) == 64 for value in upstream["source_sha256"].values()))
        shell_path = fixture["config"]["shell"]
        self.assertEqual(shell_path, fixture["shell_select_invocation"]["executable"])
        self.assertTrue(Path(shell_path).is_absolute())
        # v2.2.7 ShellSelect.args() passes custom shell commands as `-c <command>`.
        self.assertEqual(
            fixture["shell_select_invocation"]["argv"], ["-c", "printf opencode-2.2.7-shell-ok"]
        )

    @unittest.skipUnless(platform.system() == "Linux" and shutil.which("bwrap"), "requires Linux bubblewrap")
    def test_v227_shellselect_invocation_reaches_the_reviewed_launcher(self):
        fixture = json.loads(FIXTURE.read_text())
        invocation = fixture["shell_select_invocation"]
        # Replace the fixture's deployment path with this checkout's executable.
        command = [str(LAUNCHER), *invocation["argv"]]
        with persistent_workspace() as (parent, root):
            result = subprocess.run(
                command,
                cwd=root,
                env={
                    **os.environ,
                    "VEASEL_REAL_TASK_ROOT": str(root),
                    "VEASEL_REAL_TASK_PARENT": str(parent),
                    "VEASEL_BWRAP": shutil.which("bwrap") or "",
                },
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "opencode-2.2.7-shell-ok")


class OpenCodeShellSandboxTests(unittest.TestCase):
    def test_fails_closed_for_missing_configuration_and_outside_workspace(self):
        with persistent_workspace() as (parent, root):
            env = {"PATH": os.environ.get("PATH", "")}
            missing = subprocess.run(
                [str(LAUNCHER), "-c", "true"], cwd=root, env=env, text=True, capture_output=True, check=False
            )
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("VEASEL_REAL_TASK_ROOT is required", missing.stderr)

            outside = subprocess.run(
                [str(LAUNCHER), "-c", "true"],
                cwd=root,
                env={**env, "VEASEL_REAL_TASK_ROOT": str(root / "other"),
                     "VEASEL_REAL_TASK_PARENT": str(parent), "VEASEL_BWRAP": INVALID_ROOT_PROBE},
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(outside.returncode, 0)
            self.assertIn("existing directory", outside.stderr)

            fake_home = root / "simulated-home"
            ssh_dir = fake_home / ".ssh"
            ssh_dir.mkdir(parents=True)
            ssh = subprocess.run(
                [str(LAUNCHER), "-c", "true"],
                cwd=root,
                env={
                    **env,
                    "HOME": str(fake_home),
                    "VEASEL_REAL_TASK_ROOT": str(ssh_dir),
                    "VEASEL_REAL_TASK_PARENT": str(parent),
                    "VEASEL_BWRAP": INVALID_ROOT_PROBE,
                },
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(ssh.returncode, 0)
            self.assertIn("direct child", ssh.stderr)

            alias = root.parent / f"{root.name}-alias"
            alias.symlink_to(ssh_dir)
            try:
                symlink_root = subprocess.run(
                    [str(LAUNCHER), "-c", "true"],
                    cwd=root,
                    env={**env, "VEASEL_REAL_TASK_ROOT": str(alias),
                         "VEASEL_REAL_TASK_PARENT": str(parent), "VEASEL_BWRAP": INVALID_ROOT_PROBE},
                    text=True,
                    capture_output=True,
                    check=False,
                )
            finally:
                alias.unlink()
            self.assertNotEqual(symlink_root.returncode, 0)
            self.assertIn("direct child", symlink_root.stderr)

            repository = subprocess.run(
                [str(LAUNCHER), "-c", "true"],
                cwd=root,
                env={**env, "VEASEL_REAL_TASK_ROOT": str(REPOSITORY_ROOT),
                     "VEASEL_REAL_TASK_PARENT": str(parent), "VEASEL_BWRAP": INVALID_ROOT_PROBE},
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(repository.returncode, 0)
            self.assertIn("direct child", repository.stderr)

            nested_root = root / "arbitrary-nested-parent" / "veasel-real-task-nested"
            nested_root.mkdir(parents=True)
            nested = subprocess.run(
                [str(LAUNCHER), "-c", "true"],
                cwd=root,
                env={**env, "VEASEL_REAL_TASK_ROOT": str(nested_root),
                     "VEASEL_REAL_TASK_PARENT": str(parent), "VEASEL_BWRAP": INVALID_ROOT_PROBE},
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(nested.returncode, 0)
            self.assertIn("direct child", nested.stderr)

            temporary_parent = subprocess.run(
                [str(LAUNCHER), "-c", "true"],
                cwd=root,
                env={**env, "VEASEL_REAL_TASK_ROOT": str(root),
                     "VEASEL_REAL_TASK_PARENT": "/tmp", "VEASEL_BWRAP": INVALID_ROOT_PROBE},
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(temporary_parent.returncode, 0)
            self.assertIn("persistent", temporary_parent.stderr)

            parent.chmod(0o755)
            try:
                permissive_parent = subprocess.run(
                    [str(LAUNCHER), "-c", "true"],
                    cwd=root,
                    env={**env, "VEASEL_REAL_TASK_ROOT": str(root),
                         "VEASEL_REAL_TASK_PARENT": str(parent), "VEASEL_BWRAP": INVALID_ROOT_PROBE},
                    text=True,
                    capture_output=True,
                    check=False,
                )
            finally:
                parent.chmod(0o700)
            self.assertNotEqual(permissive_parent.returncode, 0)
            self.assertIn("mode 0700", permissive_parent.stderr)

    def test_rejects_non_opencode_invocation_shape(self):
        result = subprocess.run(
            [str(LAUNCHER), "--", "true"],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 64)
        self.assertIn("expected OpenCode shell invocation", result.stderr)

    def test_rejects_hardlinks_inside_git_without_modifying_outside_inode(self):
        with persistent_workspace() as (workspace_parent, workspace):
            outside_sentinel = workspace_parent / "outside-sentinel.txt"
            outside_sentinel.write_text("outside-content-preserved")
            git_object = workspace / ".git" / "objects" / "hardlinked-object"
            git_object.parent.mkdir(parents=True)
            os.link(outside_sentinel, git_object)

            self.assertEqual(os.stat(workspace).st_dev, os.stat(outside_sentinel).st_dev)
            self.assertEqual(os.stat(git_object).st_nlink, 2)
            result = subprocess.run(
                    [str(LAUNCHER), "-c", "printf changed > .git/objects/hardlinked-object"],
                    cwd=workspace,
                    env={
                        "PATH": os.environ.get("PATH", ""),
                        "VEASEL_REAL_TASK_ROOT": str(workspace),
                        "VEASEL_REAL_TASK_PARENT": str(workspace_parent),
                        "VEASEL_BWRAP": INVALID_ROOT_PROBE,
                    },
                    text=True,
                    capture_output=True,
                    check=False,
                )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("hard-linked regular file", result.stderr)
            self.assertEqual(outside_sentinel.read_text(), "outside-content-preserved")
            outside_sentinel.unlink()

    @unittest.skipUnless(platform.system() == "Linux" and shutil.which("bwrap"), "requires Linux bubblewrap")
    def test_minimal_runtime_supports_git_and_installed_language_runtimes(self):
        with persistent_workspace() as (workspace_parent, workspace):
            command = r'''set -eu
git --version >/dev/null
git -c init.defaultBranch=main init -q .
git status --short >/dev/null
if [ -x /usr/bin/python3 ]; then python3 -c 'assert 1 + 1 == 2'; fi
if [ -x /usr/bin/node ]; then node --eval 'if (1 + 1 !== 2) process.exit(1)'; fi
if [ -x /usr/bin/npm ]; then npm --version >/dev/null; fi
printf runtime-ok
'''
            result = subprocess.run(
                [str(LAUNCHER), "-c", command],
                cwd=workspace,
                env={
                    "PATH": os.environ.get("PATH", ""),
                    "VEASEL_REAL_TASK_ROOT": str(workspace),
                    "VEASEL_REAL_TASK_PARENT": str(workspace_parent),
                    "VEASEL_BWRAP": shutil.which("bwrap") or "",
                },
                text=True,
                capture_output=True,
                timeout=15,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "runtime-ok")

    @unittest.skipUnless(platform.system() == "Linux" and shutil.which("bwrap"), "requires Linux bubblewrap")
    def test_tool_process_cannot_read_proxy_token_or_reach_loopback_proxy(self):
        if not Path("/proc").is_dir():
            self.skipTest("requires Linux procfs")
        if not Path("/usr/bin/python3").is_file():
            self.skipTest("requires /usr/bin/python3 in the reviewed runtime allowlist")
        self.assertTrue(HOST_FILESYSTEM_CANARY.is_file())
        self.assertTrue(HOST_FILESYSTEM_CANARY.read_bytes())
        with persistent_workspace() as (workspace_parent, workspace):
            nested = workspace / "src"
            nested.mkdir(parents=True)

            listener = socket.socket()
            listener.bind(("127.0.0.1", 0))
            listener.listen(2)
            listener.settimeout(0.35)
            port = listener.getsockname()[1]
            # Prove the OpenCode-side host namespace can reach the loopback
            # endpoint before exercising the isolated child shell.
            with socket.create_connection(listener.getsockname(), timeout=1):
                accepted, _address = listener.accept()
                accepted.close()

            python_probe = r'''import glob, os, socket
for key in ("OPENAI_API_KEY", "META_API_KEY", "PROXY_BEARER_TOKEN", "VEASEL_MODEL_API_KEY"):
    assert key not in os.environ, key
for path in glob.glob("/proc/[0-9]*/environ"):
    try:
        contents = open(path, "rb").read()
    except OSError:
        continue
    for key in (b"OPENAI_API_KEY=", b"META_API_KEY=", b"PROXY_BEARER_TOKEN=", b"VEASEL_MODEL_API_KEY="):
        assert key not in contents, path
try:
    connection = socket.create_connection(("127.0.0.1", PORT), timeout=0.5)
except OSError:
    pass
else:
    connection.close()
    raise SystemExit("isolated shell reached the host loopback proxy")
assert {name for _index, name in socket.if_nameindex()} <= {"lo"}
with open("/proc/net/route") as routes:
    assert all(line.split()[1] != "00000000" for line in routes.readlines()[1:])
assert os.getcwd() == "/tmp/workspace/src", os.getcwd()
open("child-result.txt", "w").write("isolated-write-ok")
try:
    with open("/etc/hostname", "rb") as canary:
        canary.read()
except OSError:
    pass
else:
    raise SystemExit("isolated shell read the host filesystem canary")
'''.replace("PORT", str(port))
            command = f'/usr/bin/python3 -c {shlex.quote(python_probe)}'
            env = dict(os.environ)
            env.update({key: SECRET for key in SECRET_KEYS})
            env["VEASEL_REAL_TASK_ROOT"] = str(workspace)
            env["VEASEL_REAL_TASK_PARENT"] = str(workspace_parent)
            env["VEASEL_BWRAP"] = shutil.which("bwrap") or ""
            try:
                result = subprocess.run(
                    [str(LAUNCHER), "-c", command],
                    cwd=nested,
                    env=env,
                    text=True,
                    capture_output=True,
                    timeout=10,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((nested / "child-result.txt").read_text(), "isolated-write-ok")
                with self.assertRaises(socket.timeout):
                    listener.accept()
            finally:
                listener.close()


if __name__ == "__main__":
    unittest.main()
