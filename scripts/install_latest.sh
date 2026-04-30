#!/usr/bin/env bash
set -euo pipefail

REPO="${MISSION_SWIPE_REPO:-steven-alva/MissionSwipe}"
APP_NAME="MissionSwipe"
PREFERRED_INSTALL_DIR="${MISSION_SWIPE_INSTALL_DIR:-/Applications}"
OPEN_AFTER_INSTALL="${MISSION_SWIPE_OPEN:-1}"

log() {
  printf '[MissionSwipe installer] %s\n' "$*"
}

fail() {
  printf '[MissionSwipe installer] ERROR: %s\n' "$*" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v ditto >/dev/null 2>&1 || fail "ditto is required"
command -v unzip >/dev/null 2>&1 || fail "unzip is required"

LATEST_RELEASE_URL="https://github.com/$REPO/releases/latest"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/missionswipe-install.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

log "Checking latest release from https://github.com/$REPO"
resolved_latest_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' "$LATEST_RELEASE_URL")"
tag_name="${resolved_latest_url##*/}"

[[ -n "$tag_name" ]] || fail "Could not read latest release tag"
[[ "$tag_name" == v* ]] || fail "Could not resolve a version tag from $LATEST_RELEASE_URL"

version="${tag_name#v}"
download_url="https://github.com/$REPO/releases/download/$tag_name/$APP_NAME-$version-macos.zip"

zip_path="$TMP_DIR/$APP_NAME.zip"
extract_dir="$TMP_DIR/extract"
mkdir -p "$extract_dir"

log "Downloading $tag_name"
curl -fL --progress-bar -o "$zip_path" "$download_url"

log "Extracting app"
unzip -q "$zip_path" -d "$extract_dir"

source_app="$extract_dir/$APP_NAME.app"
[[ -d "$source_app" ]] || fail "Downloaded zip did not contain $APP_NAME.app"
[[ -x "$source_app/Contents/MacOS/$APP_NAME" ]] || fail "$APP_NAME executable is missing"

install_dir="$PREFERRED_INSTALL_DIR"
if ! mkdir -p "$install_dir" 2>/dev/null || [[ ! -w "$install_dir" ]]; then
  install_dir="$HOME/Applications"
  mkdir -p "$install_dir"
  log "No write access to $PREFERRED_INSTALL_DIR; using $install_dir"
fi

target_app="$install_dir/$APP_NAME.app"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  log "Stopping running $APP_NAME"
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  sleep 0.5
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

log "Installing to $target_app"
rm -rf "$target_app"
ditto "$source_app" "$target_app"

if command -v xattr >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$target_app" >/dev/null 2>&1 || true
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --verify --deep --strict "$target_app" >/dev/null 2>&1 || log "Installed app signature could not be verified"
fi

log "Installed $APP_NAME $tag_name"

if [[ "$OPEN_AFTER_INSTALL" == "1" ]]; then
  log "Opening $APP_NAME"
  open "$target_app"
fi

log "Done"
