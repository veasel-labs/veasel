#!/bin/sh
set -eu

: "${VEASEL_VERSION:?Set VEASEL_VERSION to an exact published Veasel release without the leading v}"
harbor_bin="${HARBOR_BIN:-harbor}"
jobs_dir="${HARBOR_JOBS_DIR:-/tmp/veasel-harbor-jobs}"

PYTHONPATH=".:${PYTHONPATH:-}" "$harbor_bin" run \
	--path benchmarks/harbor/smoke-task \
	--agent benchmarks.harbor.veasel_agent:VeaselCode \
	--ak "veasel_version=$VEASEL_VERSION" \
	--model openai/smoke-model \
	--ae OPENAI_API_KEY=test-only-key \
	--ae OPENAI_BASE_URL=http://127.0.0.1:8080/v1 \
	--jobs-dir "$jobs_dir"
