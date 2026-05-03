#!/usr/bin/env bash
set -euo pipefail

REPO="${MISSION_SWIPE_REPO:-steven-alva/MissionSwipe}"
APP_NAME="MissionSwipe"
BUNDLE_ID="io.github.stevenalva.MissionSwipe"
PREFERRED_INSTALL_DIR="${MISSION_SWIPE_INSTALL_DIR:-/Applications}"
OPEN_AFTER_INSTALL="${MISSION_SWIPE_OPEN:-1}"
CLEAN_DUPLICATES="${MISSION_SWIPE_CLEAN_DUPLICATES:-1}"

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

EXISTING_APPS=()

canonical_app_path() {
  local app_path="$1"
  local parent_dir
  local app_name
  parent_dir="$(dirname "$app_path")"
  app_name="$(basename "$app_path")"

  if [[ -d "$parent_dir" ]]; then
    printf '%s/%s\n' "$(cd "$parent_dir" && pwd -P)" "$app_name"
  else
    printf '%s\n' "$app_path"
  fi
}

is_known_missionswipe_app() {
  local app_path="$1"
  local bundle_id

  [[ -d "$app_path" ]] || return 1
  [[ -x "$app_path/Contents/MacOS/$APP_NAME" ]] || return 1

  bundle_id="$(defaults read "$app_path/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
  [[ "$bundle_id" == "$BUNDLE_ID" ]]
}

add_existing_app() {
  local app_path="$1"
  local canonical_path
  local existing_path

  [[ -n "$app_path" ]] || return 0
  [[ "$app_path" != "$TMP_DIR/"* ]] || return 0
  is_known_missionswipe_app "$app_path" || return 0

  canonical_path="$(canonical_app_path "$app_path")"
  if [[ ${#EXISTING_APPS[@]} -gt 0 ]]; then
    for existing_path in "${EXISTING_APPS[@]}"; do
      [[ "$(canonical_app_path "$existing_path")" != "$canonical_path" ]] || return 0
    done
  fi

  EXISTING_APPS+=("$app_path")
}

discover_existing_apps() {
  add_existing_app "/Applications/$APP_NAME.app"
  add_existing_app "$HOME/Applications/$APP_NAME.app"
  add_existing_app "$HOME/$APP_NAME.app"
  add_existing_app "$HOME/Downloads/$APP_NAME.app"
  add_existing_app "$HOME/Desktop/$APP_NAME.app"

  if command -v mdfind >/dev/null 2>&1; then
    while IFS= read -r app_path; do
      add_existing_app "$app_path"
    done < <(mdfind 'kMDItemFSName == "MissionSwipe.app"' 2>/dev/null || true)
  fi
}

can_install_to_dir() {
  local install_dir="$1"
  mkdir -p "$install_dir" 2>/dev/null && [[ -w "$install_dir" ]]
}

choose_target_app() {
  local existing_app
  local existing_parent

  if [[ -n "${MISSION_SWIPE_INSTALL_DIR:-}" ]]; then
    if ! can_install_to_dir "$PREFERRED_INSTALL_DIR"; then
      fail "No write access to explicit install dir: $PREFERRED_INSTALL_DIR"
    fi
    target_app="$PREFERRED_INSTALL_DIR/$APP_NAME.app"
    return
  fi

  if [[ "${#EXISTING_APPS[@]}" -gt 0 ]]; then
    log "Found existing MissionSwipe installation(s):"
    for existing_app in "${EXISTING_APPS[@]}"; do
      log "  $existing_app"
    done

    for existing_app in "${EXISTING_APPS[@]}"; do
      existing_parent="$(dirname "$existing_app")"
      if can_install_to_dir "$existing_parent"; then
        log "Updating existing installation at $existing_app"
        target_app="$existing_app"
        return
      fi
    done

    log "Existing installation locations are not writable; choosing a writable install location"
  fi

  if can_install_to_dir "$PREFERRED_INSTALL_DIR"; then
    target_app="$PREFERRED_INSTALL_DIR/$APP_NAME.app"
    return
  fi

  local fallback_dir="$HOME/Applications"
  mkdir -p "$fallback_dir"
  log "No write access to $PREFERRED_INSTALL_DIR; using $fallback_dir"
  target_app="$fallback_dir/$APP_NAME.app"
}

remove_duplicate_apps() {
  local target_app="$1"
  local target_canonical
  local app_path

  [[ "$CLEAN_DUPLICATES" == "1" ]] || return 0
  [[ ${#EXISTING_APPS[@]} -gt 0 ]] || return 0

  target_canonical="$(canonical_app_path "$target_app")"
  for app_path in "${EXISTING_APPS[@]}"; do
    [[ "$(canonical_app_path "$app_path")" != "$target_canonical" ]] || continue

    if rm -rf "$app_path" 2>/dev/null; then
      log "Removed duplicate installation: $app_path"
    else
      log "Could not remove duplicate installation: $app_path"
    fi
  done
}

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

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  log "Stopping running $APP_NAME"
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  sleep 0.5
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

discover_existing_apps
target_app=""
choose_target_app
remove_duplicate_apps "$target_app"

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
