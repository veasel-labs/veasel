#!/usr/bin/env bash
# Runs the Focus journeys in a resource-limited, network-less container with its own virtual
# display. The host's display/session is never involved. Wrap this script in your heavy-job
# launcher (e.g. ~/.local/bin/bounded) on a shared workstation.
#
# env: VEASEL_BIN      built `veasel` backend binary (host path, mounted read-only)
#      BUN_BIN         bun binary for the TUI-client probe (J9)
#      OUT_DIR         writable host dir that receives test-results/evidence/results.json
#      IMAGE           image tag (default veasel-e2e-focus:local)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
: "${VEASEL_BIN:?}" "${BUN_BIN:=/usr/bin/bun}" "${OUT_DIR:?}"
IMAGE="${IMAGE:-veasel-e2e-focus:local}"
# A missing bind-mount source makes Docker create a root-owned directory in its place; refuse instead.
for bin in "$VEASEL_BIN" "$BUN_BIN"; do
  if [[ ! -f "$bin" || ! -x "$bin" ]]; then
    echo "run-focus-journeys: $bin is not an executable file" >&2
    exit 2
  fi
done
mkdir -p "$OUT_DIR"

# --no-sandbox is required INSIDE the container only: --cap-drop=ALL removes the capabilities
# Chromium's namespace sandbox needs. The container itself is the sandbox boundary.
docker run --rm --name "veasel-e2e-$$" \
  --memory=3g --memory-swap=3g --cpus=2 --pids-limit=1024 \
  --cap-drop=ALL --security-opt no-new-privileges --network=none \
  --user "$(id -u):$(id -g)" --read-only \
  --tmpfs /tmp:rw,exec,size=1g --tmpfs /scratch:rw,exec,size=1g --shm-size=512m \
  -v "$repo:/work:ro" \
  -v "$VEASEL_BIN:/opt/bin/veasel:ro" -v "$BUN_BIN:/opt/bin/bun:ro" \
  -v "$OUT_DIR:/out:rw" \
  -e HOME=/scratch/home -e TMPDIR=/scratch/tmp -e XDG_CACHE_HOME=/scratch/cache \
  -e VEASEL_BACKEND_BIN=/opt/bin/veasel \
  -e VEASEL_SECRET_STORE=file -e VEASEL_E2E_EVIDENCE_DIR=/out/evidence \
  -e PLAYWRIGHT_JSON_OUTPUT_NAME=/out/results.json -e PATH=/opt/bin:/usr/bin:/bin \
  "$IMAGE" \
  bash -c 'mkdir -p /scratch/home /scratch/tmp /scratch/cache && xvfb-run -a -s "-screen 0 1440x900x24" \
    node /work/desktop/node_modules/@playwright/test/cli.js test -c playwright.focus.config.ts "$@"' _ "$@"
