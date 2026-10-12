#!/usr/bin/env bash
# Rewrite the changelog at the top of existing GitHub releases.
# Idempotent: a previous changelog block is replaced, and GitHub's
# auto-generated "Full Changelog" line is dropped.
#
#   scripts/backfill-release-notes.sh [--dry-run] [tag...]
set -euo pipefail

dry_run=
if [[ ${1:-} == --dry-run ]]; then
  dry_run=1
  shift
fi

repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
cd "$(git rev-parse --show-toplevel)"
git fetch --tags --quiet

tags=("$@")
if ((${#tags[@]} == 0)); then
  while read -r t; do tags+=("$t"); done < <(gh release list --limit 1000 --json tagName -q '.[].tagName')
fi

for tag in "${tags[@]}"; do
  remainder=$(gh release view "$tag" --json body -q .body |
    awk '/<!-- changelog:start -->/ { skip = 1 } !skip && !/^\*\*Full Changelog\*\*: / { print } /<!-- changelog:end -->/ { skip = 0 }' |
    sed -e '/./,$!d')
  notes=$(
    echo '<!-- changelog:start -->'
    scripts/changelog.sh "$tag" "$repo"
    echo '<!-- changelog:end -->'
    if [[ -n $remainder ]]; then
      echo
      echo "$remainder"
    fi
  )
  if [[ -n $dry_run ]]; then
    printf '===== %s =====\n%s\n\n' "$tag" "$notes"
  else
    gh release edit "$tag" --notes "$notes" >/dev/null
    echo "updated $tag"
  fi
done
