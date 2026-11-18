#!/usr/bin/env bash
# Run shard $1 of $2 of tools/ci/extra-v-tests.txt: every listed V test file is
# run with its own `v test`; failures do not stop the shard, all are reported.
set -uo pipefail
shard="${1:?shard index}"; count="${2:?shard count}"
mapfile -t files < <(grep -vE '^\s*(#|$)' tools/ci/extra-v-tests.txt)
failed=()
i=0
for f in "${files[@]}"; do
  if (( i % count == shard )); then
    echo "::group::v test $f"
    if ! v test "$f"; then failed+=("$f"); fi
    echo "::endgroup::"
  fi
  i=$((i + 1))
done
if (( ${#failed[@]} )); then
  echo "::error::failed V test files (shard $shard/$count): ${failed[*]}"
  exit 1
fi
echo "shard $shard/$count: all V test files passed"
