"""Harbor installed-agent adapter for Veasel Code.

This adapter deliberately requires an exact Veasel release and Bubblewrap.
Harbor supplies the disposable task environment; Veasel additionally contains
autonomous shell commands with its Linux filesystem and network namespace.
"""

from __future__ import annotations

import json
import re
import shlex
import uuid
from pathlib import Path
from typing import Annotated, override

from pydantic import Field

from harbor.agents.installed.base import (
    BaseInstalledAgent,
    PackageSpec,
    with_prompt_template,
)
from harbor.agents.model_connection import ModelConnectionSpec
from harbor.agents.options import Cli, InstalledAgentOptions
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext
from harbor.models.trajectories import Trajectory


class VeaselOptions(InstalledAgentOptions):
    veasel_version: Annotated[str, Cli("--veasel-version")] = Field(
        description="Exact Veasel release version, without a leading v."
    )
    provider_override: Annotated[str | None, Cli("--veasel-provider")] = Field(
        default=None,
        description="Optional Veasel provider ID, for example openai-compatible.",
    )
    timeout_seconds: Annotated[
        int | None,
        Cli("--veasel-timeout"),
    ] = Field(default=None, description="Maximum Veasel task duration in seconds.")


_VEASEL_HARBOR_PROVIDERS = frozenset(
    {
        "openai",
        "openai-responses",
        "anthropic",
        "gemini",
        "openai-compatible",
        "opencode-go",
        "meta",
    }
)

# Overrides that keep Harbor's model family while selecting a Veasel transport.
_OPENAI_FAMILY_OVERRIDES = frozenset({"openai-compatible", "openai-responses"})


def _veasel_provider(
    provider: str | None, model_name: str | None, provider_override: str | None = None
) -> tuple[str, str]:
    """Resolve only Veasel's documented provider IDs; reject silent remapping."""
    def normalize(value: str) -> str:
        return {"google": "gemini"}.get(value, value)

    if not model_name or "/" not in model_name:
        raise ValueError("Harbor model must use provider/model format")
    model_provider, model = model_name.split("/", maxsplit=1)
    model_provider = normalize(model_provider)
    configured_provider = normalize(provider or model_provider)
    if configured_provider != model_provider:
        raise ValueError("Harbor model provider does not match its model identifier")
    selected = normalize(provider_override) if provider_override else configured_provider
    if selected != configured_provider and not (
        selected in _OPENAI_FAMILY_OVERRIDES and configured_provider == "openai"
    ):
        raise ValueError("Veasel provider override must match Harbor's configured model provider")
    if selected not in _VEASEL_HARBOR_PROVIDERS:
        raise ValueError(f"Veasel does not support Harbor provider {selected!r}")
    if not model:
        raise ValueError("Harbor model identifier must not be empty")
    return selected, model


def _metadata_from_veasel_result(result: dict[str, object]) -> dict[str, object]:
    """Forward only provider-reported usage; never invent cost or cache hits."""
    metadata: dict[str, object] = {
        "veasel_status": result.get("status"),
        "veasel_provider": result.get("provider"),
        "veasel_model": result.get("model"),
        "cost": "unavailable_from_provider_adapter",
    }
    if result.get("usage_reported") is True:
        usage: dict[str, object] = {
            "input_tokens": result.get("input_tokens", 0),
            "output_tokens": result.get("output_tokens", 0),
            "reported": True,
        }
        if result.get("cache_reported") is True:
            usage["cache_read_tokens"] = result.get("cache_read_tokens", 0)
            usage["cache_creation_tokens"] = result.get("cache_creation_tokens", 0)
            usage["cache_reported"] = True
        metadata["usage"] = usage
    else:
        metadata["usage"] = "unavailable_from_provider_adapter"
    if result.get("session_usage_reported") is True:
        session_usage: dict[str, object] = {
            "completed_turns": result.get("session_completed_turns", 0),
            "reported_turns": result.get("session_reported_turns", 0),
            "input_tokens": result.get("session_input_tokens", 0),
            "output_tokens": result.get("session_output_tokens", 0),
            "reported": True,
        }
        if result.get("session_cache_reported") is True:
            session_usage["cache_read_tokens"] = result.get("session_cache_read_tokens", 0)
            session_usage["cache_creation_tokens"] = result.get(
                "session_cache_creation_tokens", 0
            )
            session_usage["cache_reported"] = True
        metadata["session_usage"] = session_usage
    return metadata


class VeaselCode(BaseInstalledAgent):
    """Run the Veasel CLI inside Harbor's disposable task environment."""

    SYSTEM_PACKAGES = {
        **BaseInstalledAgent.SYSTEM_PACKAGES,
        "bubblewrap": PackageSpec(
            commands=("bwrap",),
            packages={
                "apt-get": ("bubblewrap",),
                "dnf": ("bubblewrap",),
                "yum": ("bubblewrap",),
                "apk": ("bubblewrap",),
            },
        ),
    }
    MODEL_CONNECTION = ModelConnectionSpec(passthrough=True)
    options_model = VeaselOptions

    @property
    def veasel_version(self) -> str:
        version = self.options.veasel_version if self.options else None
        if not version or not re.fullmatch(
            r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?", version
        ):
            raise ValueError("Set --veasel-version to an exact numeric Veasel release")
        return version

    @staticmethod
    @override
    def name() -> str:
        return "veasel-code"

    @override
    def version(self) -> str | None:
        try:
            return self.veasel_version
        except ValueError:
            return None

    @override
    async def install(self, environment: BaseEnvironment) -> None:
        await self.ensure_system_dependencies(
            environment, ("bubblewrap", "curl", "coreutils", "tar", "python3")
        )
        version = self.veasel_version
        archive = "veasel-Linux.tar.gz"
        base = f"https://github.com/veasel-labs/veasel/releases/download/v{version}"
        install_dir = f"$HOME/.local/share/veasel/{version}"
        command = (
            "set -eu; command -v curl >/dev/null; command -v sha256sum >/dev/null; "
            "command -v tar >/dev/null; "
            "python3 -c 'import platform,sys; name,version=platform.libc_ver(); parts=tuple(int(part) for part in version.split(\".\")[:2]); sys.exit(0 if name == \"glibc\" and parts >= (2, 35) else 1)' "
            "|| { echo 'Veasel Linux releases require glibc 2.35 or newer' >&2; exit 2; }; "
            "test \"$(uname -s)\" = Linux; "
            "case \"$(uname -m)\" in x86_64|amd64) ;; *) echo 'unsupported Veasel Harbor architecture' >&2; exit 2 ;; esac; "
            f"mkdir -p \"{install_dir}\" \"$HOME/.local/bin\"; "
            f"curl --fail --silent --show-error --location {shlex.quote(base + '/' + archive)} -o /tmp/{archive}; "
            f"curl --fail --silent --show-error --location {shlex.quote(base + '/SHA256SUMS')} -o /tmp/veasel-SHA256SUMS; "
            "python3 -c 'import hashlib,pathlib,sys; archive=pathlib.Path(sys.argv[1]); lines=pathlib.Path(sys.argv[2]).read_text().splitlines(); matches=[line.split(maxsplit=1)[0] for line in lines if len(line.split(maxsplit=1)) == 2 and line.split(maxsplit=1)[1].strip() == archive.name]; actual=hashlib.sha256(archive.read_bytes()).hexdigest(); sys.exit(0 if len(matches) == 1 and matches[0] == actual else 1)' "
            f"/tmp/{archive} /tmp/veasel-SHA256SUMS; "
            f"tar -xzf /tmp/{archive} -C \"{install_dir}\"; "
            f"test -x \"{install_dir}/veasel\"; "
            f"ln -sfn \"{install_dir}/veasel\" \"$HOME/.local/bin/veasel\"; "
            f"test \"$(\"$HOME/.local/bin/veasel\" --version)\" = {shlex.quote('Veasel Code ' + version)}"
        )
        await self.exec_as_agent(environment, command=command)

    @override
    def get_version_command(self) -> str | None:
        return '"$HOME/.local/bin/veasel" --version'

    @override
    def parse_version(self, stdout: str) -> str:
        prefix = "Veasel Code "
        for line in stdout.splitlines():
            if line.startswith(prefix):
                return line.removeprefix(prefix).strip()
        raise ValueError("Could not parse Veasel version output")

    @override
    def populate_context_post_run(self, context: AgentContext) -> None:
        result_path = self.logs_dir / "veasel-result.json"
        if not result_path.is_file():
            return
        try:
            result = json.loads(result_path.read_text())
        except (OSError, json.JSONDecodeError):
            return
        if isinstance(result, dict):
            context.metadata = {
                **(context.metadata or {}),
                **_metadata_from_veasel_result(result),
            }

    @override
    def convert_trajectory(self, logs_dir: Path) -> Trajectory | None:
        trajectory_path = logs_dir / "trajectory.json"
        if not trajectory_path.is_file():
            return None
        return Trajectory.model_validate_json(trajectory_path.read_text())

    @override
    @with_prompt_template
    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        access = self.model_connection
        provider_override = self.options.provider_override if self.options else None
        provider, model = _veasel_provider(access.provider, self.model_name, provider_override)
        api_key = access.api_key
        configured_base_url = access.configured_base_url
        if provider == "opencode-go":
            # Harbor 0.24.0 derives OPENCODE_GO_API_KEY for this provider slug,
            # while Veasel and OpenCode Console use OPENCODE_API_KEY.
            api_key = api_key or self._get_env("OPENCODE_API_KEY")
            configured_base_url = configured_base_url or self._get_env(
                "OPENCODE_BASE_URL"
            )
        if not api_key:
            raise ValueError(f"Harbor did not provide credentials for {provider}")
        timeout = (
            self.options.timeout_seconds
            if self.options and self.options.timeout_seconds is not None
            else 1800
        )
        if timeout < 1 or timeout > 86400:
            raise ValueError("Veasel timeout must be between 1 and 86400 seconds")

        env = {
            "VEASEL_ALLOW_AUTONOMOUS_EXECUTION": "1",
            "VEASEL_DATA_DIR": f"/tmp/veasel-harbor-{uuid.uuid4().hex}",
            "VEASEL_MODEL_PROVIDER": provider,
            "VEASEL_MODEL": model,
            "VEASEL_MODEL_API_KEY": api_key,
        }
        if configured_base_url:
            env["VEASEL_MODEL_BASE_URL"] = configured_base_url

        trace = "/logs/agent/trajectory.json"
        result = "/logs/agent/veasel-result.json"
        command = (
            "set -eu; "
            f"test \"${{VEASEL_MODEL_PROVIDER:-}}\" = {shlex.quote(provider)}; "
            f"test \"${{VEASEL_MODEL:-}}\" = {shlex.quote(model)}; "
            "test -n \"${VEASEL_MODEL_API_KEY:-}\"; "
            "mkdir -p /logs/agent \"$VEASEL_DATA_DIR\"; "
            "VEASEL_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind((\"127.0.0.1\", 0)); print(s.getsockname()[1]); s.close()'); "
            "export VEASEL_PORT; "
            "server_log=/logs/agent/veasel-server.log; "
            f"\"$HOME/.local/bin/veasel\" serve >\"$server_log\" 2>&1 & server_pid=$!; "
            "trap 'kill \"$server_pid\" 2>/dev/null || true; wait \"$server_pid\" 2>/dev/null || true' EXIT; "
            "attempt=0; until curl --fail --silent --show-error \"http://127.0.0.1:$VEASEL_PORT/v1/health\" >/dev/null; do "
            "attempt=$((attempt + 1)); if [ \"$attempt\" -ge 100 ]; then cat \"$server_log\" >&2; exit 1; fi; sleep 0.1; done; "
            "set +e; \"$HOME/.local/bin/veasel\" run --autonomous --json "
            f"--timeout {timeout} --workspace \"$PWD\" "
            f"--trace-file {shlex.quote(str(trace))} "
            f"--prompt {shlex.quote(instruction)} "
            f">{shlex.quote(result)} 2>&1; run_status=$?; set -e; "
            f"cat {shlex.quote(result)}; "
            "if [ \"$run_status\" -ne 0 ]; then cat \"$server_log\" >&2; fi; "
            "exit \"$run_status\""
        )
        await self.exec_as_agent(environment, command=command, env=env, timeout_sec=timeout + 30)


def validate_trace(path: Path) -> dict[str, object]:
    """Small helper for local artifact checks; Harbor remains the authority."""
    trace = json.loads(path.read_text())
    if not isinstance(trace, dict) or trace.get("schema_version") != "ATIF-v1.8":
        raise ValueError("Expected an ATIF-v1.8 trajectory")
    if not trace.get("steps"):
        raise ValueError("Trajectory has no steps")
    return trace
