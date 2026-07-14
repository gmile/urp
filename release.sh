#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <patch|minor|major>" >&2
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

[[ $# -eq 1 ]] || usage
[[ -z "$(git status --porcelain)" ]] || fail "working tree must be clean"
[[ "$(git branch --show-current)" == "main" ]] || fail "releases must be prepared from main"

upstream=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null) ||
  fail "main has no upstream; fetch and configure origin/main first"
read -r behind ahead < <(git rev-list --left-right --count "${upstream}...HEAD")
[[ "$behind" == "0" && "$ahead" == "0" ]] ||
  fail "main must match ${upstream}; fetch, pull, and push pending commits first"

bump_type="$1"
current=$(tr -d '[:space:]' < VERSION)
[[ "$current" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] ||
  fail "VERSION is not valid semantic version: ${current}"

major=${BASH_REMATCH[1]}
minor=${BASH_REMATCH[2]}
patch=${BASH_REMATCH[3]}

case "$bump_type" in
  patch) new="$major.$minor.$((patch + 1))" ;;
  minor) new="$major.$((minor + 1)).0" ;;
  major) new="$((major + 1)).0.0" ;;
  *) usage ;;
esac

grep --fixed-strings --quiet '## [Unreleased]' CHANGELOG.md ||
  fail "CHANGELOG.md has no [Unreleased] section"

unreleased=$(
  awk '
    /^## \[Unreleased\]$/ { in_section = 1; next }
    in_section && /^## / { exit }
    in_section { print }
  ' CHANGELOG.md
)

grep --quiet '[^[:space:]]' <<< "$unreleased" ||
  fail "CHANGELOG.md [Unreleased] section is empty"

git rev-parse --verify --quiet "refs/tags/v${new}" >/dev/null &&
  fail "tag v${new} already exists"

today=$(date -u +%Y-%m-%d)
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

awk -v version="$new" -v date="$today" '
  /^## \[Unreleased\]$/ {
    print
    print ""
    print "## [v" version "] - " date
    next
  }
  { print }
' CHANGELOG.md > "$tmp"

printf '%s\n' "$new" > VERSION
mv "$tmp" CHANGELOG.md
trap - EXIT

git add VERSION CHANGELOG.md
git commit -m "Release v${new}"
git tag --annotate --message "v${new}" "v${new}"

echo
echo "Release v${new} prepared. Publish only after main CI succeeds:"
echo "  git push origin main"
echo "  git push origin v${new}"
