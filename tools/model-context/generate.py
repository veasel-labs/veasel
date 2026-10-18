#!/usr/bin/env python3
"""Regenerate model_context.generated.v from schedule.json (no network)."""
from __future__ import annotations

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCHEDULE = pathlib.Path(__file__).with_name("schedule.json")
OUTPUT = ROOT / "model_context.generated.v"


def main() -> int:
    check = "--check" in sys.argv
    doc = json.loads(SCHEDULE.read_text())
    commit = doc["source"]["commit"]
    models = doc["models"]
    lines = [
        "// Generated from tools/model-context/schedule.json. Do not edit by hand.",
        f"// Models.dev pin: https://github.com/anomalyco/models.dev/tree/{commit}",
        "module main",
        "",
        f"const embedded_model_context_source_commit = '{commit}'",
        "",
        "fn embedded_model_context_entries() []ModelContextEntry {",
        "\treturn [",
    ]
    for e in models:
        lines.append(
            "\t\tModelContextEntry{ "
            f"provider: '{e['provider']}', model: '{e['model']}', "
            f"context_tokens: {int(e['context_tokens'])} }},"
        )
    lines += ["\t]", "}", ""]
    text = "\n".join(lines)
    if check:
        current = OUTPUT.read_text() if OUTPUT.exists() else ""
        if current != text:
            print(f"{OUTPUT.relative_to(ROOT)} is stale; run python3 tools/model-context/generate.py", file=sys.stderr)
            return 1
        print("model context generated source is up to date")
        return 0
    OUTPUT.write_text(text)
    print(f"wrote {OUTPUT.relative_to(ROOT)} ({len(models)} models)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
