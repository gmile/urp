#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <patch|minor|major>"
  exit 1
}

[[ $# -eq 1 ]] || usage

bump_type="$1"
current=$(cat VERSION | tr -d '[:space:]')
IFS='.' read -r major minor patch <<< "$current"

case "$bump_type" in
  patch) new="$major.$minor.$((patch + 1))" ;;
  minor) new="$major.$((minor + 1)).0" ;;
  major) new="$((major + 1)).0.0" ;;
  *) usage ;;
esac

today=$(date -u +%Y-%m-%d)

echo "Bumping version: $current -> $new"

# Update VERSION
echo "$new" > VERSION

# Stamp changelog — replace [Unreleased] with version + date
if ! grep -q '## \[Unreleased\]' CHANGELOG.md; then
  echo "Error: no [Unreleased] section in CHANGELOG.md" >&2
  git checkout VERSION
  exit 1
fi
tmp=$(mktemp)
sed "s/## \[Unreleased\]/## [v$new] - $today/" CHANGELOG.md > "$tmp" && mv "$tmp" CHANGELOG.md

# Commit and tag
git add VERSION CHANGELOG.md
git commit -m "Release v$new"
git tag -m "v$new" "v$new"

echo ""
echo "Release v$new prepared!"
echo ""
echo "Run this to publish:"
echo "  git push origin main v$new"
