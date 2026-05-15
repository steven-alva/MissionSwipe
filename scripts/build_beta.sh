#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MissionSwipe"
STAMP="$(date -u +%Y%m%d%H%M)"

export MISSION_SWIPE_VERSION="${MISSION_SWIPE_BETA_VERSION:-0.7.8-beta.$STAMP}"
export MISSION_SWIPE_BUILD="${MISSION_SWIPE_BETA_BUILD:-$STAMP}"
export MISSION_SWIPE_DEV_BUILD="${MISSION_SWIPE_DEV_BUILD:-1}"

"$ROOT_DIR/scripts/build_app.sh"

versioned_zip="$ROOT_DIR/dist/$APP_NAME-$MISSION_SWIPE_VERSION-macos.zip"
beta_zip="$ROOT_DIR/dist/$APP_NAME-beta-macos.zip"

cp "$versioned_zip" "$beta_zip"

echo "Beta package: $beta_zip"
echo "Versioned package: $versioned_zip"
