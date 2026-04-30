# Changelog

## Unreleased

## 0.6.3

- Changed swipe-down minimize to default on for new installs.

## 0.6.2

- Added lightweight Terminal install/update script at `scripts/install_latest.sh`.
- Replaced swipe-down minimize cursor movement with a short-lived stale-thumbnail click guard.
- After a Mission Control minimize succeeds, the app suppresses one click on the old hover frame so the minimized window is less likely to restore immediately.
- Improved local/release signing behavior by preferring an Apple Development signing identity when available, while falling back to ad-hoc signing.
- Reduced repeated Accessibility permission prompts by adding a cooldown around the system prompt request.
- When Accessibility permission is requested on first launch, MissionSwipe now explains that the app should be reopened and then quits so the permission state is applied cleanly.

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
