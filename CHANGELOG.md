# Changelog

## Unreleased

## 0.7.8

- **Fixed: Smart Fit racing the target app's AX queue.** Same-display moves used to fire `setPosition` + `setSize` + `setPosition` back-to-back within a few milliseconds, expecting the target process to keep up. On slower configurations (observed on Chrome / M4 / 16GB / macOS 26.3.1) the size write would arrive before the position write had been processed, and Chrome would apply only the position — leaving the window at Chrome's default 500×474 size and triggering the adaptive pass to minimize "stubborn" windows that were actually just lagging. `setFrame` now pumps the run loop ~20-30ms between each AX write (matching what the cross-display path already did, just shorter). Arrange visibly takes ~200-400ms longer for a 4-window scene, but every window lands at its target instead of half of them being treated as stubborn and minimized.

## 0.7.7

- **Reverted 0.7.6's preemptive minimize.** The "physical-fit" check that ran before dispatching the arrange pipeline was minimizing windows that previously fit fine on the local 14" display (saw a 5-window arrange suddenly drop to 4). The whole pre-pass — the `idealMinCellInches`/`acceptableMinCellInches` constants, the PPI-based predictor, the `physicallyFitWindows` reducer, and its call site — has been removed. Smart Fit now goes straight from the capacity cap into the layout dispatch, exactly like 0.7.5 did. The 0.7.6 primary-placement fix (right/left-swipe no longer gets clobbered by the adaptive pass) is preserved.
- **Diagnostics → "Capture scene to clipboard".** New one-shot diagnostic button that produces a multi-section text dump covering: macOS version + hardware model + CPU arch + memory + accessibility-permission state; every screen's frame, visible frame, backing scale, physical mm/inches, diagonal, native pixels, and PPI (logical *and* native); the full Smart Fit / gesture / probe configuration; and every visible window's CG bounds + AX role/subrole/position/size + app bundle ID + executable path + AX attribute list + minimized/fullscreen/main/focused flags. Output is copied to the clipboard *and* mirrored into the log. Designed for cross-machine debugging — paste it into a bug report and the difference between two machines (scaling, PWA bundle IDs, AX availability, etc.) is right there.

## 0.7.6

- **Resolution-independent arrange.** Smart Fit now uses each screen's *physical* width (in inches), not its pixel width, to decide whether a layout will fit. The minimum acceptable cell width is 4.5 inches (target 5.0 inches), tuned so Chrome and similarly-sized apps consistently accept it. Practically this means a 14" laptop produces the same arrange outcome whether it's set to "Default" or "More Space" scaling — same number of visible windows, same layout pattern, just at different pixel counts.
- **Smart Fit minimizes the right number of windows automatically.** When the chosen layout would produce cells narrower than the physical minimum, Smart Fit reduces window count one at a time (least-recently-used first) until cells fit. No new layouts are introduced — the algorithm simply hands off to the layout for one fewer window. HUD continues to surface the count via "已收纳 X 个窗口" / "Minimized X".
- **Fixed: primary-placement swipe being overridden by adaptive layout.** When the user right- or left-swiped to make a window the primary (filling half the screen), the adaptive second pass could rearrange every window — including the primary — into a generic grid, ignoring the user's intent. The primary-placement path now skips the adaptive second pass entirely, preserving the chosen primary even if some secondaries refuse their cell sizes.

## 0.7.5

- Cleaned up `Settings → Diagnostics` from a wall of three toggles + four buttons to just two items: `Debug logging` and a `Diagnostics panel…` button.
- New `Diagnostics panel` sub-window groups every troubleshooting tool by purpose:
  - **Logs**: shows the log file path, a `Copy` action with a dropdown for line count (50 / 100 / 200 / 500 / Entire log), and a `Reveal in Finder` button.
  - **Last action report**: the previous Copy Last Report button with its own context.
  - **System window scan**: the `Dump CG windows` and `Dump AX windows` buttons with a note that they're most useful while Mission Control is open.
  - **Experimental probes**: the Mission Control gesture probe and input event probe toggles, with warnings that they flood the log.
- Default log copy size dropped from 300 lines to 50; user-pasteable into a chat without truncation.

## 0.7.4

- Added per-window-count layout pickers in `Settings → Smart Fit → Advanced…`. Each layout option shows a thumbnail preview of the cell geometry, so you can see what you're picking before applying.
  - **3 windows**: `1 big + 2 small` (default), `3 equal columns`
  - **4 windows**: `2×2 grid` (default), `1 big + 3 small`
  - **5 windows**: `3 over 2 (balanced)` (default), `Left 2 big + right 3 small`, `Bottom 2 big + top 3 small`
- Each pick is remembered per user; default values match the original 0.7.x defaults, so upgrading does not change anyone's existing layout unless they tap a thumbnail.

## 0.7.3

- Added `Copy Recent Log` button to `Settings → Diagnostics` so you can paste the latest ~300 log lines from inside the app without opening a terminal.
- Reverted the 0.7.2 default 3-window layout from "3 equal columns" back to the original "1 big + 2 stacked" layout. The column variant will return as an explicit layout option in 0.7.4 rather than as a forced default change.

## 0.7.2

- `arrangeThreeWindows` now uses a three equal-width columns layout (full-height each) instead of the old "1 big + 2 stacked" layout. The old layout asked the primary window for the full screen height, which Chrome (and several other apps) routinely refuse — that left the left half of the screen empty. Three columns make every window short-and-wide, which apps respect far more reliably and keeps the screen filled.
- Stubborn detection now catches windows that refuse to *grow* as well as windows that refuse to *shrink*. A Chrome window that ignores a full-height target and stays at half-height is now identified and triggers the adaptive second pass.

## 0.7.1

- Smart Fit no longer drops flexible windows when one neighbour is stubborn. The adaptive second pass used to treat each non-stubborn window's first-pass tile size as a hard pack width, so a single stubborn window (e.g. NetEase Music at 1056x752) could force every flexible Chrome alongside it to be minimized. Flexible windows are now packed using a smaller flex footprint (480x320) and stretched into the remaining row width afterwards.
- `Copy Last Action Report` now shows a HUD confirmation on both paths: "Report copied" on success, and "No recent report — close or minimize a window first" when there is no close/minimize report yet (the previous build silently did nothing).

## 0.7.0

- Added Smart Fit arrange: a screen-size-aware tiling pass that caps the number of arranged windows based on display physical size, picks the most-recently-used windows, and decides what to do with the rest according to a user-configurable overflow strategy.
- Added an adaptive second pass that re-tiles around windows refusing to shrink, so stubborn apps no longer break the layout.
- Added a per-screen-size capacity profile editable from `Settings → Smart Fit → Customize capacities…` (defaults: 5 / 6 / 6 / 9 / 9 across ≤15", 16-17", 21-24", 27", 30"+).
- Added `Settings → Smart Fit → Advanced…` for picking the overflow strategy and tuning overlap tolerance:
  - **Minimize overflow** (default): minimize the least-recently-used windows that no longer fit cleanly.
  - **Tolerate light overlap**: keep every window on screen, accept some bleed.
  - **Stack with peek edges**: when tile produces overlap, cascade all windows by size — biggest at the back, smallest on top — with peek strips on the top-left of each layer.
- Added an overlap tolerance slider (6%-50%) so Smart Fit only triggers its overflow strategy when overlap is actually meaningful.
- Added a brief HUD confirmation after Smart Fit collapses, adapts, or stacks windows. The action is reversible from `Undo Last Arrange`.
- `Undo Last Arrange` now restores windows that Smart Fit minimized in addition to restoring their previous frames.
- Tile gap reduced from 10 pt to 4 pt for denser arrangements.
- Cross-display arrange writes now follow position → size → position with small settle delays so windows arrive at the correct size on their destination display.
- Removed the `Control + Option + W` global hotkey and `GlobalHotkeyManager`. MissionSwipe is gesture-first now; the menu entry still triggers the same close action without a key equivalent.
- Build script learns a dev-mode flag: local single-arch builds (`BUILD_UNIVERSAL=0`) default debug logging on. Universal release builds stay quiet.

## 0.6.7

- Added a Settings window from the menu bar with core gesture, layout, diagnostics, system, and language controls.
- Added Chinese and English UI language selection for the menu, Settings, permission prompts, gesture HUD, and layout preview.
- Added a Layout Dashboard option in Settings for previewing directional layouts before they apply.
- Improved swipe feedback with HUD progress and completion motion for close, minimize, blank-area arrange, and primary left/right layout gestures.
- Kept the simple left/right primary layout gesture available when Layout Dashboard is off.

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
