#!/usr/bin/env bash
# Rewrite the changelog at the top of existing GitHub releases.
# Idempotent: a previous changelog block is replaced, and the notes
# GitHub's generate_release_notes used to append are dropped.
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

# Drops our changelog block and GitHub's generated sections. Exits 2 on
# an unterminated block rather than dropping everything after it.
strip_changelog() {
  awk '
    /<!-- changelog:start -->/ { block = 1; next }
    block { if (/<!-- changelog:end -->/) block = 0; next }
    /^## (What'\''s Changed|New Contributors)$/ { generated = 1; next }
    generated && /^## / { generated = 0 }
    generated || /^\*\*Full Changelog\*\*: / { next }
    { print }
    END { if (block) exit 2 }
  ' | sed -e '/./,$!d'
}

failed=0
for tag in "${tags[@]}"; do
  if ! remainder=$(gh release view "$tag" --json body -q .body | strip_changelog); then
    echo "skipped $tag: changelog block has no end marker, fix the release body by hand" >&2
    failed=1
    continue
  fi
  if ! changelog=$(scripts/changelog.sh "$tag" "$repo"); then
    failed=1
    continue
  fi
  notes=$changelog${remainder:+$'\n\n'$remainder}
  if [[ -n $dry_run ]]; then
    printf '===== %s =====\n%s\n\n' "$tag" "$notes"
  else
    gh release edit "$tag" --notes "$notes" >/dev/null
    echo "updated $tag"
  fi
done
exit "$failed"
