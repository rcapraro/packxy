#!/usr/bin/env bash
# Print the Markdown changelog for a release tag, built from the
# conventional-commit subjects since the previous v* tag.
#
#   scripts/changelog.sh v3.4.0 [owner/repo]
set -euo pipefail

tag=${1:?usage: changelog.sh <tag> [owner/repo]}
repo=${2:-${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}}
url="https://github.com/$repo"

# Only v-prefixed tags have GitHub releases; bare 1.1.x tags are strays.
prev=$(git tag --list 'v*' --sort=v:refname | awk -v t="$tag" '$0 == t { print p; exit } { p = $0 }')
range=${prev:+$prev..}$tag

breaking=() features=() fixes=() others=()
while IFS=$'\t' read -r sha subject breaking_trailer; do
  if [[ $subject =~ ^([a-z-]+)(\(([^\)]+)\))?(!)?:\ (.*)$ ]]; then
    type=${BASH_REMATCH[1]} scope=${BASH_REMATCH[3]} bang=${BASH_REMATCH[4]} text=${BASH_REMATCH[5]}
  else
    type=other scope= bang= text=$subject
  fi
  line="- ${scope:+**$scope:** }$text ([${sha:0:7}]($url/commit/$sha))"
  if [[ -n $bang || -n $breaking_trailer ]]; then
    breaking+=("$line")
    continue
  fi
  case $type in
    feat) features+=("$line") ;;
    fix) fixes+=("$line") ;;
    *) others+=("$line") ;;
  esac
done < <(git log --no-merges --format='%H%x09%s%x09%(trailers:key=BREAKING CHANGE,valueonly,separator= )' "$range")

section() {
  local title=$1
  shift
  (($#)) || return 0
  printf '### %s\n\n' "$title"
  printf '%s\n' "$@"
  printf '\n'
}

echo "## What's changed"
echo
section "⚠️ Breaking changes" ${breaking[@]+"${breaking[@]}"}
section "Features" ${features[@]+"${features[@]}"}
section "Bug fixes" ${fixes[@]+"${fixes[@]}"}
section "Other changes" ${others[@]+"${others[@]}"}
if [[ -n $prev ]]; then
  echo "**Full changelog**: $url/compare/$prev...$tag"
else
  echo "**Full changelog**: $url/commits/$tag"
fi
