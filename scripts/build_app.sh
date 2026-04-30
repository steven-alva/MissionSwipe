#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MissionSwipe"
VERSION="${MISSION_SWIPE_VERSION:-0.6.3}"
BUILD_NUMBER="${MISSION_SWIPE_BUILD:-9}"
BUNDLE_ID="${MISSION_SWIPE_BUNDLE_ID:-io.github.stevenalva.MissionSwipe}"
MIN_MACOS="${MISSION_SWIPE_MIN_MACOS:-13.0}"
BUILD_UNIVERSAL="${BUILD_UNIVERSAL:-1}"
SIGNING_IDENTITY="${MISSION_SWIPE_CODESIGN_IDENTITY:-}"

DIST_DIR="$ROOT_DIR/dist"
BUILD_DIR="$ROOT_DIR/build/release"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION-macos.zip"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

if [[ "$BUILD_UNIVERSAL" == "1" ]]; then
  ARCHES=("arm64" "x86_64")
else
  ARCHES=("$(uname -m)")
fi

rm -rf "$APP_DIR" "$BUILD_DIR" "$ZIP_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$BUILD_DIR"

SOURCES=("$ROOT_DIR"/MissionSwipe/*.swift)
BUILT_BINARIES=()

for ARCH in "${ARCHES[@]}"; do
  OUTPUT="$BUILD_DIR/$APP_NAME-$ARCH"
  swiftc \
    -O \
    -whole-module-optimization \
    -target "$ARCH-apple-macosx$MIN_MACOS" \
    -sdk "$SDK_PATH" \
    "${SOURCES[@]}" \
    -o "$OUTPUT"
  BUILT_BINARIES+=("$OUTPUT")
done

if [[ "${#BUILT_BINARIES[@]}" -gt 1 ]]; then
  lipo -create "${BUILT_BINARIES[@]}" -output "$MACOS_DIR/$APP_NAME"
else
  cp "${BUILT_BINARIES[0]}" "$MACOS_DIR/$APP_NAME"
fi

chmod +x "$MACOS_DIR/$APP_NAME"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>LSMinimumSystemVersion</key>
	<string>$MIN_MACOS</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSAccessibilityUsageDescription</key>
	<string>MissionSwipe needs Accessibility permission to close the Mission Control window thumbnail under the mouse cursor.</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:/ { print $2; exit }')"
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
  echo "Signing with $SIGNING_IDENTITY"
  codesign --force --sign "$SIGNING_IDENTITY" "$APP_DIR" >/dev/null
else
  echo "Signing with ad-hoc identity"
  codesign --force --sign - "$APP_DIR" >/dev/null
fi

ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

echo "Built $APP_DIR"
echo "Packaged $ZIP_PATH"
