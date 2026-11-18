#!/usr/bin/env bash
# Immutable publish of a verified prerelease. Never overwrites assets.
#
#   publish-release.sh <upload-dir> <notes-file>
#
# Env: RELEASE_TAG, RELEASE_VERSION, RELEASE_COMMIT (full 40-char SHA), GH_REPO,
#      GH_TOKEN. Uses the `gh` CLI (PATH-overridable for tests).
set -euo pipefail

dir="${1:?upload dir}"
notes="${2:?notes file}"
: "${RELEASE_TAG:?}" "${RELEASE_VERSION:?}" "${RELEASE_COMMIT:?}" "${GH_REPO:?}"

[[ "$RELEASE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
  echo "::error::RELEASE_COMMIT must be a full 40-char SHA, got '$RELEASE_COMMIT'"; exit 1; }

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-.}}/release-verify.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# 1. The staged set must be self-consistent: SHA256SUMS covers every other file.
(
  cd "$dir"
  sha256sum --check SHA256SUMS
  diff <(find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | LC_ALL=C sort) <(awk '{print $2}' SHA256SUMS | LC_ALL=C sort) \
    || { echo "::error::SHA256SUMS does not cover exactly the upload set"; exit 1; }
)

# verify_remote <release-id>: re-download every asset and check it byte-for-byte.
verify_remote() {
  local id="$1" dl="$work/dl-$1"
  rm -rf "$dl"; mkdir -p "$dl"
  local rows
  rows="$(gh api --paginate "repos/$GH_REPO/releases/$id/assets" --jq '.[] | "\(.id)\t\(.name)"')"
  diff <(cut -f2 <<<"$rows" | LC_ALL=C sort) <(find "$dir" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort) >/dev/null \
    || { echo "::error::remote asset set differs from the verified upload set"; return 1; }
  while IFS=$'\t' read -r aid name; do
    gh api -H 'Accept: application/octet-stream' "repos/$GH_REPO/releases/assets/$aid" > "$dl/$name"
  done <<<"$rows"
  (cd "$dl" && cp "$dir/SHA256SUMS" . && sha256sum --check SHA256SUMS) \
    || { echo "::error::re-downloaded assets do not match SHA256SUMS"; return 1; }
}

# 2. Look for an existing release (published or draft) for this tag.
row="$(gh api --paginate "repos/$GH_REPO/releases" \
  --jq ".[] | select(.tag_name == \"$RELEASE_TAG\") | \"\(.id)\t\(.draft)\t\(.target_commitish)\"" | head -n1)"
if [[ -n "$row" ]]; then
  IFS=$'\t' read -r id draft existing <<<"$row"
  if [[ "$draft" == "true" ]]; then
    # A draft is not public and cannot have been pinned downstream; it is
    # leftover from an interrupted run, so discard it and start clean.
    echo "Removing leftover unpublished draft $id for $RELEASE_TAG"
    gh api -X DELETE "repos/$GH_REPO/releases/$id" >/dev/null
  else
    if [[ "$existing" != "$RELEASE_COMMIT" ]]; then
      echo "::error::Release tag collision: $RELEASE_TAG points to $existing, but this verified build is for $RELEASE_COMMIT. Re-run CI after the existing release is visible to the version planner."
      exit 1
    fi
    # Published release for the same commit: never touch it.
    if verify_remote "$id"; then
      echo "Release $RELEASE_TAG already published with identical verified assets; nothing to do."
      exit 0
    fi
    echo "::error::$RELEASE_TAG is already published with different assets. Refusing to overwrite published assets."
    exit 1
  fi
fi

# 3. Create as draft (tag does not exist yet), upload, verify, then publish.
files=()
for f in "$dir"/*; do files+=("$f"); done
gh release create "$RELEASE_TAG" "${files[@]}" \
  --draft --prerelease --target "$RELEASE_COMMIT" \
  --title "Veasel Code $RELEASE_VERSION" --notes-file "$notes" --generate-notes
id="$(gh api --paginate "repos/$GH_REPO/releases" \
  --jq ".[] | select(.tag_name == \"$RELEASE_TAG\" and .draft == true) | .id" | head -n1)"
[[ -n "$id" ]] || { echo "::error::draft release not found after create"; exit 1; }
verify_remote "$id" || { echo "::error::draft left unpublished for inspection (id $id)"; exit 1; }
gh api -X PATCH "repos/$GH_REPO/releases/$id" -F draft=false -F prerelease=true >/dev/null
echo "Published $RELEASE_TAG with verified assets."
