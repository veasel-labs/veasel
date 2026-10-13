#!/usr/bin/env python3
"""Refresh Veasel's compatible provider presets from a pinned Models.dev commit.

This is catalog maintenance tooling only. The Veasel binary uses checked-in,
generated V data and has no Python or Models.dev runtime dependency.
"""

from __future__ import annotations

import argparse
import io
import json
import re
import tarfile
import tomllib
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit
from urllib.error import HTTPError, URLError


ROOT = Path(__file__).resolve().parents[2]
CATALOG = Path(__file__).with_name("providers.json")
REPOSITORY = "https://github.com/anomalyco/models.dev"
ARCHIVE_URL = "https://codeload.github.com/anomalyco/models.dev/tar.gz/{commit}"
COMMIT_PATTERN = re.compile(r"^[a-f0-9]{40}$")
PROVIDER_ID_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
MAX_ARCHIVE_BYTES = 20 * 1024 * 1024
MAX_ARCHIVE_MEMBERS = 50000
MAX_PROVIDER_TOML_BYTES = 256 * 1024


def compatible_preset(path: str, metadata: dict[str, object]) -> dict[str, object] | None:
    """Map only fixed HTTPS OpenAI-compatible providers with one credential."""
    provider_id = Path(path).parent.name
    name = metadata.get("name")
    api = metadata.get("api")
    env = metadata.get("env")
    docs = metadata.get("doc")
    if metadata.get("npm") != "@ai-sdk/openai-compatible":
        return None
    if not isinstance(name, str) or not name.strip():
        return None
    if not PROVIDER_ID_PATTERN.fullmatch(provider_id):
        return None
    if not isinstance(api, str) or not _is_public_https_url(api):
        return None
    if not isinstance(env, list) or len(env) != 1 or not isinstance(env[0], str):
        return None
    if not re.fullmatch(r"[A-Z0-9_]+", env[0]):
        return None
    if not isinstance(docs, str) or not _is_public_https_url(docs, allow_query=True, allow_fragment=True):
        return None
    return {
        "id": provider_id,
        "name": name.strip(),
        "description": "OpenAI-compatible Chat Completions API",
        "protocol": "openai-compatible",
        "api": api,
        "environment_key": env[0],
        "documentation_url": docs,
        "requires_api_key": True,
        "source": "models.dev",
        "models_dev_source": f"providers/{provider_id}/provider.toml",
    }


def _is_public_https_url(value: str, *, allow_query: bool = False, allow_fragment: bool = False) -> bool:
    """Accept only absolute HTTPS URLs without credentials or templates."""
    try:
        parsed = urlsplit(value)
        return (
            parsed.scheme == "https"
            and bool(parsed.hostname)
            and parsed.username is None
            and parsed.password is None
            and (allow_query or not parsed.query)
            and (allow_fragment or not parsed.fragment)
            and not any(char in value for char in "{}$")
            and (parsed.port is None or 1 <= parsed.port <= 65535)
        )
    except ValueError:
        return False


def read_compatible_presets(archive: bytes) -> list[dict[str, object]]:
    presets: dict[str, dict[str, object]] = {}
    if len(archive) > MAX_ARCHIVE_BYTES:
        raise ValueError("Models.dev snapshot archive exceeds the 20 MiB safety limit")
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as bundle:
        for member_count, member in enumerate(bundle, start=1):
            if member_count > MAX_ARCHIVE_MEMBERS:
                raise ValueError("Models.dev snapshot has too many archive members")
            if not member.isfile() or "/providers/" not in member.name or not member.name.endswith("/provider.toml"):
                continue
            if member.size > MAX_PROVIDER_TOML_BYTES:
                raise ValueError(f"provider metadata is unexpectedly large: {member.name}")
            stream = bundle.extractfile(member)
            if stream is None:
                continue
            metadata = tomllib.loads(stream.read().decode("utf-8"))
            preset = compatible_preset(member.name, metadata)
            if preset is None:
                continue
            provider_id = str(preset["id"])
            if provider_id in presets:
                raise ValueError(f"duplicate Models.dev provider ID: {provider_id}")
            presets[provider_id] = preset
    return [presets[key] for key in sorted(presets)]


def merge_presets(
    existing: list[dict[str, object]], presets: list[dict[str, object]]
) -> list[dict[str, object]]:
    """Refresh compatible metadata without changing shipped connection contracts."""
    merged = {provider["id"]: provider.copy() for provider in existing}
    refreshed_ids = {preset["id"] for preset in presets}
    for provider_id, provider in merged.items():
        if provider.get("source") == "models.dev" and provider_id not in refreshed_ids:
            provider["source"] = "veasel-curated"
            provider.pop("models_dev_source", None)
    for source_preset in presets:
        preset = source_preset.copy()
        previous = merged.get(preset["id"])
        if previous is not None:
            if previous.get("protocol") != preset.get("protocol"):
                # Keep native Veasel adapters such as Meta Responses instead of
                # relabeling them as a generic upstream OpenAI-compatible API.
                previous["source"] = "veasel-curated"
                previous.pop("models_dev_source", None)
                continue
            if previous.get("source") == "veasel-curated":
                # Preserve Veasel's provenance when an upstream ID overlaps a
                # curated connection preset.
                preset["source"] = "veasel-curated"
                preset.pop("models_dev_source", None)
            if previous.get("api"):
                preset["api"] = previous["api"]
            if "environment_key" in previous:
                preset["environment_key"] = previous["environment_key"]
            if "requires_api_key" in previous:
                preset["requires_api_key"] = previous["requires_api_key"]
            if previous.get("documentation_url"):
                preset["documentation_url"] = previous["documentation_url"]
        merged[preset["id"]] = preset
    return sorted(merged.values(), key=lambda item: item["id"])


def download_snapshot(commit: str) -> bytes:
    request = urllib.request.Request(
        ARCHIVE_URL.format(commit=commit),
        headers={"User-Agent": "Veasel-provider-catalog-maintenance"},
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            if response.status != 200:
                raise RuntimeError(f"Models.dev returned HTTP {response.status}")
            content_length = response.headers.get("Content-Length")
            if content_length is not None and int(content_length) > MAX_ARCHIVE_BYTES:
                raise RuntimeError("Models.dev snapshot archive exceeds the 20 MiB safety limit")
            archive = response.read(MAX_ARCHIVE_BYTES + 1)
            if len(archive) > MAX_ARCHIVE_BYTES:
                raise RuntimeError("Models.dev snapshot archive exceeds the 20 MiB safety limit")
            return archive
    except (HTTPError, URLError, TimeoutError) as error:
        raise RuntimeError(f"could not download pinned Models.dev commit {commit}: {error}") from error


def refresh(commit: str, archive: bytes) -> int:
    if not COMMIT_PATTERN.fullmatch(commit):
        raise ValueError("Models.dev revision must be a full 40-character commit SHA")
    selected = json.loads(CATALOG.read_text(encoding="utf-8"))
    presets = read_compatible_presets(archive)
    if len(presets) < 150:
        raise ValueError(f"expected at least 150 compatible provider presets; found {len(presets)}")

    # Provider IDs already shipped by Veasel are user-facing config contracts.
    # Keep their endpoints and credential variables, and retain curated entries
    # even if Models.dev later removes a provider.
    selected["source"]["commit"] = commit
    selected["providers"] = merge_presets(selected["providers"], presets)
    temporary = CATALOG.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(selected, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    temporary.replace(CATALOG)
    return len(presets)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--commit",
        help="refresh to this full Models.dev commit SHA (defaults to the current catalog pin)",
    )
    args = parser.parse_args()
    selected = json.loads(CATALOG.read_text(encoding="utf-8"))
    commit = args.commit or selected["source"]["commit"]
    if not COMMIT_PATTERN.fullmatch(commit):
        parser.error("--commit must be a full 40-character hexadecimal SHA")
    count = refresh(commit, download_snapshot(commit))
    print(f"Refreshed {count} compatible provider presets from {commit}.")
    print("Run node tools/provider-catalog/generate.mjs to update V data and documentation.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
