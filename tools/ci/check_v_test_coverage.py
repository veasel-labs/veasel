#!/usr/bin/env python3
"""Fail when a V test file is not executed by any CI job.

A `*_test.v` at the repo root counts as covered when it is named in
.github/workflows/ci.yml, listed in tools/ci/extra-v-tests.txt (the sharded
Linux job), or listed with a reason in tools/ci/excluded-v-tests.txt.
Run from the repository root. Exit 1 lists every gap and every stale entry.
"""
import glob
import os
import sys


def read_list(path, split_tab=False):
    items = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            items.append(line.split("\t")[0] if split_tab else line)
    return items


def main(root="."):
    os.chdir(root)
    ci = open(".github/workflows/ci.yml", encoding="utf-8").read()
    extra = read_list("tools/ci/extra-v-tests.txt")
    excluded = read_list("tools/ci/excluded-v-tests.txt", split_tab=True)
    tests = sorted(glob.glob("*_test.v"))
    problems = []
    for t in tests:
        if t not in ci and t not in extra and t not in excluded:
            problems.append(f"not run by any CI job: {t} (add it to ci.yml, tools/ci/extra-v-tests.txt, or excluded-v-tests.txt with a reason)")
    for name in extra + excluded:
        if name not in tests:
            problems.append(f"stale entry (file does not exist): {name}")
    for name in set(extra) & set(excluded):
        problems.append(f"listed in both extra and excluded: {name}")
    if extra != sorted(extra):
        problems.append("tools/ci/extra-v-tests.txt must be sorted")
    for p in problems:
        print("ERROR:", p)
    print(f"{len(tests)} V test files: {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
