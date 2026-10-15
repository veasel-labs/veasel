#!/usr/bin/env python3
"""Regenerate cost_schedule.generated.v from schedule.json (no network)."""
from __future__ import annotations

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCHEDULE = pathlib.Path(__file__).with_name("schedule.json")
OUTPUT = ROOT / "cost_schedule.generated.v"


def main() -> int:
    check = "--check" in sys.argv
    doc = json.loads(SCHEDULE.read_text())
    commit = doc["source"]["commit"]
    models = doc["models"]
    lines = [
        "// Generated from tools/cost-schedule/schedule.json. Do not edit by hand.",
        f"// Models.dev pin: https://github.com/anomalyco/models.dev/tree/{commit}",
        "module main",
        "",
        "const embedded_cost_schedule_unit = 'usd_per_million_tokens'",
        f"const embedded_cost_schedule_source_commit = '{commit}'",
        "",
        "fn embedded_cost_schedule_entries() []CostScheduleEntry {",
        "\treturn [",
    ]
    for e in models:
        cr = e.get("cache_read")
        cw = e.get("cache_write")
        cr_s = "none" if cr is None else str(float(cr))
        cw_s = "none" if cw is None else str(float(cw))
        lines.append(
            "\t\tCostScheduleEntry{ "
            f"provider: '{e['provider']}', model: '{e['model']}', "
            f"input: {float(e['input'])}, output: {float(e['output'])}, "
            f"cache_read: {cr_s}, cache_write: {cw_s} }},"
        )
    lines += ["\t]", "}", ""]
    text = "\n".join(lines)
    if check:
        current = OUTPUT.read_text() if OUTPUT.exists() else ""
        if current != text:
            print(f"{OUTPUT.relative_to(ROOT)} is stale; run python3 tools/cost-schedule/generate.py", file=sys.stderr)
            return 1
        print("cost schedule generated source is up to date")
        return 0
    OUTPUT.write_text(text)
    print(f"wrote {OUTPUT.relative_to(ROOT)} ({len(models)} models)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
