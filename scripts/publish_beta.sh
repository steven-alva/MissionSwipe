#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${MISSION_SWIPE_REPO:-steven-alva/MissionSwipe}"
BETA_TAG="${MISSION_SWIPE_BETA_TAG:-beta}"
BETA_ASSET="$ROOT_DIR/dist/MissionSwipe-beta-macos.zip"

command -v gh >/dev/null 2>&1 || {
  printf 'ERROR: gh is required to publish a beta release\n' >&2
  exit 1
}

"$ROOT_DIR/scripts/build_beta.sh"

git -C "$ROOT_DIR" tag -f "$BETA_TAG" HEAD >/dev/null
git -C "$ROOT_DIR" push -f origin "$BETA_TAG"

notes="Beta channel build. This release is for validation before promoting to the stable latest release."

if gh release view "$BETA_TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$BETA_TAG" "$BETA_ASSET" --repo "$REPO" --clobber
  gh release edit "$BETA_TAG" --repo "$REPO" --prerelease --title "MissionSwipe Beta" --notes "$notes"
else
  gh release create "$BETA_TAG" "$BETA_ASSET" --repo "$REPO" --prerelease --title "MissionSwipe Beta" --notes "$notes"
fi

printf 'Published beta release: https://github.com/%s/releases/tag/%s\n' "$REPO" "$BETA_TAG"
