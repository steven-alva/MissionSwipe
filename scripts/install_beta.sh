#!/usr/bin/env bash
set -euo pipefail

REPO="${MISSION_SWIPE_REPO:-steven-alva/MissionSwipe}"

export MISSION_SWIPE_RELEASE_TAG="${MISSION_SWIPE_RELEASE_TAG:-beta}"
export MISSION_SWIPE_ASSET_NAME="${MISSION_SWIPE_ASSET_NAME:-MissionSwipe-beta-macos.zip}"

log() {
  printf '[MissionSwipe beta installer] %s\n' "$*"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)"
if [[ -n "$script_dir" && -f "$script_dir/install_latest.sh" ]]; then
  log "Using local install_latest.sh with release tag $MISSION_SWIPE_RELEASE_TAG"
  exec "$script_dir/install_latest.sh"
fi

installer_url="https://github.com/$REPO/raw/refs/heads/main/scripts/install_latest.sh"
log "Using $installer_url with release tag $MISSION_SWIPE_RELEASE_TAG"
curl -fsSL "$installer_url" | bash
