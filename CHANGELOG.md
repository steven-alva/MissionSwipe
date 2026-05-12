# Changelog

## Unreleased

## 0.6.6

- Improved visible-window auto arrange with more stable balanced layouts for four or more windows.
- Fixed multi-display and hidden-Dock usable-area calculations so arranged windows target the correct screen bounds.
- Added arrange frame verification and retry logging when macOS or an app adjusts the requested size.
- Kept second Mission Control swipe-up arrange hidden because the gesture inference remains unstable.

## 0.6.5

- Added menu actions for `Arrange Visible Windows` and `Undo Last Arrange`.
- Added an experimental blank-area swipe-up trigger: swipe up on a Mission Control thumbnail to close it, or swipe up on empty Mission Control space to exit and arrange visible windows.
- Improved auto-arrange to collect AX windows first so same-app or same-title windows are less likely to be missed.
- Auto-arrange now uses the system visible screen frame, so hidden Dock/menu bar space can be used when macOS exposes it.
- Removed the double swipe-up trigger from the local experiment because public scroll events cannot reliably distinguish two-finger scrolls from four-finger Mission Control gestures.

## 0.6.4

- Distinguish Stage Manager-like Dock overlays from Mission Control by requiring Mission Control layout evidence before arming close/minimize gestures.
- Added a menu action to hide the MissionSwipe menu bar icon while keeping gestures running in the background.
- Updated the Terminal installer to update an existing MissionSwipe.app in place and remove duplicate MissionSwipe.app copies where possible.
- Updated the Terminal installer to avoid the GitHub Releases API, reducing unauthenticated `403` failures on some networks.

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
