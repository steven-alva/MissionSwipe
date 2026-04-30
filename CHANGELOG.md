# Changelog

## Unreleased

- Added lightweight Terminal install/update script at `scripts/install_latest.sh`.

## 0.6.1

- Move the mouse away from the minimized Mission Control thumbnail after swipe-down minimize succeeds.
- This avoids clicking a stale blue Mission Control hover frame and accidentally restoring the minimized window.

## 0.6.0

- Added experimental Mission Control swipe-down minimize.
- Added `Enable Swipe Down to Minimize (Experimental)` menu toggle, default off.
- Minimize uses the native AX minimize button first, so macOS may show its system minimize animation when available.
- Renamed the clipboard diagnostic menu item to `Copy Last Action Report`.

## 0.5.0

- Mission Control only close workflow.
- Trackpad swipe-up close with Mission Control preflight.
- Normal desktop hotkey and scroll safety rejection.
- Debug logging toggle, default off.
- Copy last successful close report from the menu.
- Manual packaging script for a shareable macOS app zip.
