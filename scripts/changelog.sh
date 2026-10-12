#!/usr/bin/env bash
# Print the Markdown changelog for a release tag, built from the
# conventional-commit subjects since the previous v* tag. The output is
# wrapped in markers so backfill-release-notes.sh can replace it in place.
#
#   scripts/changelog.sh v3.4.0 [owner/repo]
set -euo pipefail

tag=${1:?usage: changelog.sh <tag> [owner/repo]}
repo=${2:-${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}}
url="https://github.com/$repo"

git rev-parse -q --verify "refs/tags/$tag" >/dev/null || {
  echo "changelog.sh: no such tag: $tag" >&2
  exit 1
}

# The highest lower version among the tag's ancestors, so a backport on
# another branch is never picked. versionsort.suffix sorts v1.0.0-rc.1
# before v1.0.0. A final release counts from the previous final one, so
# its notes cover every change since, not just the last rc.
prev=$(git -c versionsort.suffix=- tag --merged "$tag" --list 'v*' --sort=-v:refname |
  awk -v t="$tag" 'found && (t ~ /-/ || $0 !~ /-/) { print; exit } $0 == t { found = 1 }')
range=${prev:+$prev..}$tag

breaking=() features=() fixes=() others=()
while IFS=$'\t' read -r sha subject; do
  if [[ $subject =~ ^([a-z-]+)(\(([^\)]+)\))?(!)?:\ (.*)$ ]]; then
    type=${BASH_REMATCH[1]} scope=${BASH_REMATCH[3]} bang=${BASH_REMATCH[4]} text=${BASH_REMATCH[5]}
  else
    type= scope= bang= text=$subject
  fi
  link="([${sha:0:7}]($url/commit/$sha))"
  if [[ -n $bang ]] || git log -1 --format=%b "$sha" | grep -qE '^BREAKING[ -]CHANGE:'; then
    breaking+=("- ${scope:+**$scope:** }$text $link")
    continue
  fi
  case $type in
    feat) features+=("- ${scope:+**$scope:** }$text $link") ;;
    fix) fixes+=("- ${scope:+**$scope:** }$text $link") ;;
    '') others+=("- $text $link") ;;
    *) others+=("- **$type${scope:+($scope)}:** $text $link") ;;
  esac
done < <(git log --no-merges --format='%H%x09%s' "$range")

section() {
  local title=$1
  shift
  (($#)) || return 0
  printf '### %s\n\n' "$title"
  printf '%s\n' "$@"
  printf '\n'
}

echo '<!-- changelog:start -->'
echo "## What's changed"
echo
section "⚠️ Breaking changes" ${breaking[@]+"${breaking[@]}"}
section "Features" ${features[@]+"${features[@]}"}
section "Bug fixes" ${fixes[@]+"${fixes[@]}"}
section "Other changes" ${others[@]+"${others[@]}"}
if ((${#breaking[@]} + ${#features[@]} + ${#fixes[@]} + ${#others[@]} == 0)); then
  printf 'No changes.\n\n'
fi
if [[ -n $prev ]]; then
  echo "**Full changelog**: $url/compare/$prev...$tag"
else
  echo "**Full changelog**: $url/commits/$tag"
fi
echo '<!-- changelog:end -->'
