#!/usr/bin/env python3
"""Verify a published Linux AppImage and standalone TUI share one Veasel backend.

The release manifest SHA-256 is a required trust anchor supplied by the
caller. All application data, HOME/XDG paths, logs, ports, and renderer
profiles are isolated beneath the required, previously nonexistent --work-dir.
No VEASEL_BACKEND_BIN/E2E override is set, and no default data path is derived.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import pathlib
import platform
import pty
import select
import signal
import shutil
import socket
import struct
import subprocess
import sys
import tarfile
import termios
import time
import urllib.error
import urllib.request


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_inputs(args: argparse.Namespace) -> dict:
    manifest_path = args.release_manifest.resolve(strict=True)
    appimage = args.appimage.resolve(strict=True)
    tui = args.tui.resolve(strict=True)
    cli_archive = args.cli_archive.resolve(strict=True)
    observed_manifest_sha = sha256(manifest_path)
    if observed_manifest_sha != args.manifest_sha256.lower():
        raise ValueError("release manifest digest does not match the supplied trust anchor")

    manifest = json.loads(manifest_path.read_text())
    version = manifest.get("version")
    if version != args.expected_version:
        raise ValueError(f"release version {version!r} != expected {args.expected_version!r}")
    assets = {asset.get("name"): asset for asset in manifest.get("assets", [])}
    app_asset = assets.get(appimage.name)
    tui_asset = assets.get(tui.name)
    cli_asset = assets.get(cli_archive.name)
    if app_asset is None or app_asset.get("kind") != "desktop-installer":
        raise ValueError("AppImage filename/kind is not present in the verified release manifest")
    if tui_asset is None or tui_asset.get("kind") != "standalone-tui":
        raise ValueError("TUI filename/kind is not present in the verified release manifest")
    if cli_asset is None or cli_asset.get("kind") != "cli-archive":
        raise ValueError("CLI archive filename/kind is not present in the verified release manifest")
    if app_asset.get("platform") != "linux" or tui_asset.get("platform") != "linux":
        raise ValueError("only Linux release artifacts are supported")
    if any(asset.get("arch") != "x86_64" for asset in (app_asset, tui_asset, cli_asset)) \
            or platform.machine().lower() not in ("x86_64", "amd64"):
        raise ValueError("release artifacts must target this x86_64 Linux host")
    for label, artifact, record in (("AppImage", appimage, app_asset),
                                    ("TUI", tui, tui_asset),
                                    ("CLI archive", cli_archive, cli_asset)):
        if not artifact.is_file():
            raise ValueError(f"{label} must be a regular file")
        if label != "CLI archive" and not os.access(artifact, os.X_OK):
            raise ValueError(f"{label} must be executable")
        if artifact.stat().st_size != record.get("size"):
            raise ValueError(f"{label} size does not match the release manifest")
        if sha256(artifact) != record.get("sha256"):
            raise ValueError(f"{label} digest does not match the release manifest")
    return {
        "manifest_sha256": observed_manifest_sha,
        "version": version,
        "tag": manifest.get("tag"),
        "appimage": str(appimage),
        "appimage_sha256": app_asset["sha256"],
        "tui": str(tui),
        "tui_sha256": tui_asset["sha256"],
        "cli_archive": str(cli_archive),
        "cli_archive_sha256": cli_asset["sha256"],
    }


def stage_release_cli(verified: dict, destination: pathlib.Path) -> pathlib.Path:
    """Copy only the two expected regular files out of a verified tarball."""
    destination.mkdir()
    expected = {"veasel", "veasel-tui"}
    seen = set()
    with tarfile.open(verified["cli_archive"], "r:gz") as archive:
        for member in archive.getmembers():
            if member.name not in expected:
                continue
            if not member.isfile():
                raise ValueError(f"release CLI archive member {member.name!r} is not a regular file")
            source = archive.extractfile(member)
            if source is None:
                raise ValueError(f"unable to read release CLI archive member {member.name!r}")
            target = destination / member.name
            target.write_bytes(source.read())
            target.chmod(0o755)
            seen.add(member.name)
    if seen != expected:
        raise ValueError("release CLI archive is missing its CLI or standalone TUI binary")
    if sha256(destination / "veasel-tui") != verified["tui_sha256"]:
        raise ValueError("CLI archive's TUI binary differs from the verified standalone TUI asset")
    return destination / "veasel"


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def clean_environment(home: pathlib.Path, data: pathlib.Path,
                      temp_dir: pathlib.Path, port: int) -> dict[str, str]:
    # This harness does not configure a provider or pass credentials/proxy
    # settings to child processes; it is not a network sandbox. Do not inherit
    # API keys, DBus/display sockets, cloud credentials, or caller hooks. The
    # fixed PATH intentionally hides installed coding-agent executables.
    return {
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "XDG_CACHE_HOME": str(home / ".cache"),
        "XDG_DATA_HOME": str(home / ".local" / "share"),
        "TMPDIR": str(temp_dir),
        "TMP": str(temp_dir),
        "TEMP": str(temp_dir),
        "VEASEL_DATA_DIR": str(data),
        "VEASEL_PORT": str(port),
        "TERM": "xterm-256color",
        "PATH": "/usr/bin:/bin",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "ELECTRON_DISABLE_GPU": "1",
    }


def health(data: pathlib.Path, port: int, timeout: float = 1.0) -> dict | None:
    token_path = data / "api-token"
    if not token_path.is_file():
        return None
    token = token_path.read_text().strip()
    if not token:
        return None
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/health",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.load(response)
    except (OSError, urllib.error.URLError, json.JSONDecodeError):
        return None


def eventually(func, timeout: float, label: str):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = func()
        if value:
            return value
        time.sleep(0.15)
    raise RuntimeError(f"timed out waiting for {label}")


def first_backend(data: pathlib.Path, port: int, timeout: float) -> dict | None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = health(data, port)
        if value:
            return value
        time.sleep(0.15)
    return None


def consume_tui(proc: subprocess.Popen, fd: int, timeout: float) -> bytes:
    deadline = time.monotonic() + timeout
    output = bytearray()
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            try:
                output.extend(os.read(fd, 32768))
            except OSError:
                break
            lower = bytes(output).lower()
            if b"sessions" in lower or b"connected" in lower:
                break
        elif proc.poll() is not None:
            break
    return bytes(output)


def renderer_state(port: int) -> dict[str, bool | int]:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=1) as response:
            pages = json.load(response)
        page_urls = [page.get("url", "") for page in pages if page.get("type") == "page"]
        return {
            "page_count": len(page_urls),
            "focus_page": any("/#/focus" in url for url in page_urls),
            "page_urls": page_urls,
        }
    except (OSError, urllib.error.URLError, json.JSONDecodeError):
        return {"page_count": 0, "focus_page": False, "page_urls": []}


def stop_group(process: subprocess.Popen | None) -> None:
    if process is None or process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass


def run_mode(args: argparse.Namespace, verified: dict, work_dir: pathlib.Path,
             mode: str) -> dict:
    run_root = work_dir / mode
    db = run_root / "data"
    home = run_root / "home"
    desktop_profile = run_root / "desktop-profile"
    logs = run_root / "logs"
    temp_dir = run_root / "tmp"
    cli_package = run_root / "release-cli"
    for directory in (db, home, desktop_profile, logs, temp_dir):
        directory.mkdir(parents=True)
    cli_binary = stage_release_cli(verified, cli_package)
    backend_port = free_port()
    cdp_port = free_port()
    env = clean_environment(home, db, temp_dir, backend_port)
    env.pop("VEASEL_BACKEND_BIN", None)
    env.pop("VEASEL_E2E_BACKEND_BIN", None)
    appimage_args = [
        verified["appimage"], "--appimage-extract-and-run",
        "--ozone-platform=headless", "--disable-gpu",
        f"--remote-debugging-port={cdp_port}",
        "--remote-debugging-address=127.0.0.1",
        f"--user-data-dir={desktop_profile}",
    ]
    # Run the verified CLI wrapper from the same release archive; it starts or
    # reuses the local V backend, then execs the adjacent verified release TUI.
    tui_args = [str(cli_binary), "tui"]
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
    log = (logs / "desktop.log").open("wb")
    gui: subprocess.Popen | None = None
    terminal: subprocess.Popen | None = None
    result = {
        "mode": mode,
        "status": "failed",
        "stage": "startup",
        "backend_port": backend_port,
        "artifacts_verified": True,
        "backend_override_set": False,
        "default_data_path_used": False,
    }
    try:
        if mode == "appimage-first":
            gui = subprocess.Popen(
                appimage_args, cwd=run_root, env=env, stdin=subprocess.DEVNULL,
                stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            before = first_backend(db, backend_port, args.first_launch_timeout)
            result["first_launcher"] = "AppImage"
            result["first_backend_pid"] = before.get("pid") if before else None
            result["first_launcher_started_backend"] = before is not None
            terminal = subprocess.Popen(
                tui_args, cwd=run_root, env=env, stdin=slave, stdout=slave,
                stderr=slave, start_new_session=True)
        else:
            terminal = subprocess.Popen(
                tui_args, cwd=run_root, env=env, stdin=slave, stdout=slave,
                stderr=slave, start_new_session=True)
            before = first_backend(db, backend_port, args.first_launch_timeout)
            result["first_launcher"] = "TUI"
            result["first_backend_pid"] = before.get("pid") if before else None
            result["first_launcher_started_backend"] = before is not None
            gui = subprocess.Popen(
                appimage_args, cwd=run_root, env=env, stdin=subprocess.DEVNULL,
                stdout=log, stderr=subprocess.STDOUT, start_new_session=True)

        result["stage"] = "tui-render"
        tui_output = consume_tui(terminal, master, args.tui_timeout)
        (logs / "tui.txt").write_bytes(tui_output)
        tui_visible = b"sessions" in tui_output.lower() or b"connected" in tui_output.lower()
        result["tui_visible"] = tui_visible

        result["stage"] = "shared-listener"
        after = first_backend(db, backend_port, args.startup_timeout)
        result["backend_healthy_after_both"] = after is not None
        if after:
            result["backend_version"] = after.get("version")
            result["backend_pid"] = after.get("pid")
        result["shared_listener"] = bool(
            before and after and before.get("pid") == after.get("pid")
        )

        result["stage"] = "desktop-renderer"
        try:
            desktop_state = eventually(
                lambda: (state if (state := renderer_state(cdp_port))["focus_page"] else None),
                args.renderer_timeout, "AppImage Focus route")
        except RuntimeError:
            desktop_state = renderer_state(cdp_port)
        desktop_visible = desktop_state["page_count"] > 0
        result["desktop_renderer"] = desktop_visible
        result["desktop_page_count"] = desktop_state["page_count"]
        result["desktop_focus_page"] = desktop_state["focus_page"]
        result["desktop_page_urls"] = desktop_state["page_urls"]
        result["launcher_exit_codes_before_cleanup"] = {
            "appimage": gui.poll() if gui is not None else None,
            "tui": terminal.poll() if terminal is not None else None,
        }

        failure_reasons = []
        if not before:
            failure_reasons.append(
                f"first launcher ({result['first_launcher']}) did not establish the backend")
        if not after:
            failure_reasons.append("no authenticated backend appeared on the isolated test port")
        if before and after and before.get("pid") != after.get("pid"):
            failure_reasons.append("backend PID changed after the second launcher started")
        if after and after.get("version") != verified["version"]:
            failure_reasons.append("backend version differs from the verified release")
        if not tui_visible:
            failure_reasons.append("TUI did not render a connected session view")
        if not desktop_visible:
            failure_reasons.append("AppImage renderer did not expose a page")
        elif not desktop_state["focus_page"]:
            failure_reasons.append("AppImage renderer page did not reach the expected focus route")
        if failure_reasons:
            raise RuntimeError("; ".join(failure_reasons))
        result.update(status="passed", stage="complete")
    except Exception as exc:  # Acceptance failures are results, not tracebacks.
        result["reason"] = str(exc)
        if gui is not None and gui.poll() is not None:
            result["appimage_exit_code"] = gui.returncode
        if terminal is not None and terminal.poll() is not None:
            result["tui_exit_code"] = terminal.returncode
        log.flush()
        desktop_log = (logs / "desktop.log").read_text(errors="replace")
        result["headless_gpu_fatal"] = (
            "FATAL:content/browser/gpu/gpu_data_manager_impl_private.cc" in desktop_log
            and "GPU process isn't usable" in desktop_log
        )
        tui_log = (logs / "tui.txt").read_text(errors="replace") \
            if (logs / "tui.txt").is_file() else ""
        server_log_path = db / "logs" / "server.log"
        if server_log_path.is_file():
            tui_log += "\n" + server_log_path.read_text(errors="replace")
        result["data_dir_lock_conflict"] = (
            "another Veasel backend already owns the data directory" in tui_log
        )
        current = health(db, backend_port)
        if current:
            result["observed_backend_version"] = current.get("version")
            result["observed_backend_pid"] = current.get("pid")
    finally:
        stop_group(gui)
        stop_group(terminal)
        # If an app detached its backend from the launcher group, stop it only
        # when the authenticated endpoint still reports the exact PID recorded
        # from this isolated data directory and ephemeral port.
        current = health(db, backend_port)
        expected_pid = result.get("first_backend_pid") or result.get("backend_pid") \
            or result.get("observed_backend_pid")
        if current and expected_pid and current.get("pid") == expected_pid:
            try:
                os.kill(int(expected_pid), signal.SIGTERM)
            except (ProcessLookupError, PermissionError, TypeError, ValueError):
                pass
        os.close(master)
        os.close(slave)
        log.close()
        # Electron caches are disposable and can exceed the size of all other
        # evidence. Keep the sanitized logs and summary, not the renderer cache.
        shutil.rmtree(desktop_profile, ignore_errors=True)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-manifest", required=True, type=pathlib.Path)
    parser.add_argument("--manifest-sha256", required=True,
                        help="trusted SHA-256 of the release manifest")
    parser.add_argument("--appimage", required=True, type=pathlib.Path)
    parser.add_argument("--tui", required=True, type=pathlib.Path)
    parser.add_argument("--cli-archive", required=True, type=pathlib.Path)
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--work-dir", required=True, type=pathlib.Path,
                        help="must not already exist; all state/logs stay beneath it")
    parser.add_argument("--startup-timeout", type=float, default=20)
    parser.add_argument("--first-launch-timeout", type=float, default=20,
                        help="how long to give the first launcher to establish the backend")
    parser.add_argument("--renderer-timeout", type=float, default=30)
    parser.add_argument("--tui-timeout", type=float, default=20)
    args = parser.parse_args()

    try:
        if len(args.manifest_sha256) != 64 or any(
            char not in "0123456789abcdefABCDEF" for char in args.manifest_sha256
        ):
            raise ValueError("--manifest-sha256 must contain 64 hexadecimal characters")
        verified = verify_inputs(args)
        work_dir = args.work_dir.resolve()
        manifest_dir = args.release_manifest.resolve(strict=True).parent
        if work_dir == manifest_dir or manifest_dir in work_dir.parents:
            raise ValueError("--work-dir must be outside the source evidence directory")
        work_dir.mkdir(parents=True, exist_ok=False)
    except Exception as exc:
        print(json.dumps({"acceptance": "not-run", "reason": str(exc)}), flush=True)
        return 2

    results = []
    for mode in ("appimage-first", "tui-first"):
        try:
            result = run_mode(args, verified, work_dir, mode)
        except Exception as exc:
            result = {"mode": mode, "status": "failed", "stage": "harness",
                      "reason": str(exc)}
        results.append(result)
        print(json.dumps(result, sort_keys=True), flush=True)
        # Persist after each order so an interrupted second run does not erase
        # already captured evidence from the first.
        partial = {
            "acceptance": "incomplete",
            "version": verified["version"],
            "release_tag": verified.get("tag"),
            "artifacts": verified,
            "backend_override_set": False,
            "default_data_path_used": False,
            "modes": results,
            "evidence_dir": str(work_dir),
        }
        (work_dir / "summary.json").write_text(
            json.dumps(partial, indent=2, sort_keys=True) + "\n")

    accepted = all(result.get("status") == "passed" for result in results)
    summary = {
        "acceptance": "passed" if accepted else "failed",
        "version": verified["version"],
        "release_tag": verified.get("tag"),
        "artifacts": verified,
        "backend_override_set": False,
        "default_data_path_used": False,
        "modes": results,
        "evidence_dir": str(work_dir),
    }
    (work_dir / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print(json.dumps(summary, sort_keys=True), flush=True)
    return 0 if accepted else 1


if __name__ == "__main__":
    sys.exit(main())
