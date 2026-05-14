# MissionSwipe

MissionSwipe is a macOS AppKit menu bar app. It is gesture-first: open Mission Control, then close, minimize, or rearrange windows with trackpad swipes. The product boundary is intentionally narrow — MissionSwipe only acts when Mission Control is active, so normal desktop scrolling and clicking are untouched.

## Current version: 0.7.6

0.7.0 introduces Smart Fit, a screen-size-aware tiling engine with three overflow strategies (minimize, tolerate overlap, stack with peek) and a per-screen capacity profile. The global hotkey from earlier MVPs has been retired in favour of the gesture-only product direction.

Supported today:

- AppKit menu bar app using `NSStatusItem`
- Optional menu bar icon hiding for background-only use
- Accessibility permission prompt and settings shortcut
- Mission Control likely-active detection using public CGWindowList heuristics
- Conservative Mission Control matching with confidence scoring
- Trackpad swipe-up to close while Mission Control is active
- Trackpad swipe-down to minimize while Mission Control is active
- Blank-area swipe-up and menu action to arrange visible windows
- Left/right primary-window layout gestures with optional Layout Dashboard preview
- Smart Fit arrange: caps arranged windows by display physical size, picks most-recently-used, adapts around stubborn apps
- Per-screen capacity profile (≤15" / 16-17" / 21-24" / 27" / 30"+) editable in Settings
- Overflow strategies: minimize, tolerate light overlap, or stack-with-peek cascade
- Settings window with Chinese/English language selection
- Normal desktop scroll safety rejection
- Debug logging toggle, default off (default on for local dev builds)
- Copy last successful action report to the clipboard
- Diagnostics actions for CG and AX troubleshooting
- Concise success logs, with full window dumps reserved for failures or manual debug actions

Still intentionally not implemented:

- Overlay close buttons
- Per-window X buttons
- Screen recording
- Image recognition or computer vision
- Private APIs

## Download and Install

Download the latest `MissionSwipe-*-macos.zip` from GitHub Releases, unzip it, and move `MissionSwipe.app` to Applications.

The current public build is signed when a local Apple Development identity is available, but it is not notarized yet. On first launch, macOS may show an unidentified developer warning. Use right click > Open once, then grant Accessibility permission when prompted.

Terminal install/update:

```bash
curl -fsSL https://github.com/steven-alva/MissionSwipe/raw/refs/heads/main/scripts/install_latest.sh | bash
```

The command always installs the latest GitHub release. If MissionSwipe is already installed, it updates that copy in place and removes duplicate `MissionSwipe.app` copies where possible. For new installs, it uses `/Applications`, falls back to `~/Applications` if needed, and opens MissionSwipe after installation.

## Build the app locally

Run:

```bash
scripts/build_app.sh
```

This creates:

- `dist/MissionSwipe.app`
- `dist/MissionSwipe-0.7.6-macos.zip`

The script builds a universal app for Apple Silicon and Intel Macs by default. For a faster local-only build, run:

```bash
BUILD_UNIVERSAL=0 scripts/build_app.sh
```

## How to run in Xcode

1. Open `MissionSwipe.xcodeproj` in Xcode.
2. Select the `MissionSwipe` scheme.
3. Build and run.
4. A menu bar icon appears. The app is configured as an agent app with `LSUIElement`, so it does not show a Dock icon.
5. Open Mission Control, hover a window thumbnail, and swipe up on the trackpad to close it (or swipe down to minimize).

## Required permissions

MissionSwipe needs Accessibility permission because it uses `AXUIElement` to find and press the close button of the matched window.

On launch, the app checks Accessibility permission. If permission is missing on first launch, it requests the system prompt, explains that MissionSwipe should be reopened after granting access, and quits so macOS can apply the permission cleanly. The menu also provides an `Open Accessibility Settings` item.

Path:

`System Settings > Privacy & Security > Accessibility`

After granting permission, try a gesture again. If macOS does not immediately apply the new permission, quit and relaunch MissionSwipe.

If Settings shows MissionSwipe as enabled but the logs still say `Accessibility trusted: false`:

1. Stop MissionSwipe in Xcode.
2. In Accessibility settings, turn `MissionSwipe` off and back on.
3. Run MissionSwipe again from Xcode.
4. If it is still false, reset the stale permission row:

   ```bash
   tccutil reset Accessibility io.github.stevenalva.MissionSwipe
   ```

5. Run MissionSwipe again and approve the prompt.
6. In Xcode, prefer signing with an Apple Development or Personal Team identity. If Xcode uses a changing local/ad-hoc signature, macOS can treat each rebuild as a different app for Accessibility trust.

On launch, MissionSwipe logs the current bundle identifier, bundle path, executable path, pid, and trusted state. Use those lines to confirm that the app shown in Settings is the same app currently running from Xcode.

For reliable day-to-day testing, set stable signing in Xcode:

1. Select the blue `MissionSwipe` project.
2. Select the `MissionSwipe` target.
3. Open `Signing & Capabilities`.
4. Choose your Apple Development or Personal Team.
5. Keep the bundle identifier stable as `io.github.stevenalva.MissionSwipe` unless you intentionally reset Accessibility again.

Having to run `tccutil reset` after every rebuild is a sign that macOS sees the new build as a different trusted code object. Stable signing should make the Accessibility grant persist across launches.

## Menu items

- `Close Mission Control Window`: closes the Mission Control thumbnail under the cursor (the menu version of the swipe-up gesture).
- `Arrange Visible Windows`: arranges visible desktop windows into a non-overlapping grid.
- `Undo Last Arrange`: restores the previous frames from the last arrange action.
- `Settings...`: opens gesture, layout, diagnostics, system, and language controls.
- `Check Accessibility Permission`: refreshes the menu status line.
- `Open Accessibility Settings`: opens the Accessibility privacy pane.
- `Quit MissionSwipe`: quits the background menu bar app.

The Settings window includes:

- `Mission Control mode`, `Swipe up to close`, `Swipe down to minimize`, and `Blank-area swipe up to arrange`
- `Smart Fit arrange`, with two sub-pages:
  - `Customize capacities...` lets you tune how many windows fit per screen size (≤15" / 16-17" / 21-24" / 27" / 30"+)
  - `Advanced...` picks the overflow strategy (minimize, tolerate overlap, stack with peek) and tunes the overlap tolerance
- `Layout Dashboard`, which enables preview/confirmation for directional layouts
- `Language`, with `English` and `中文`
- Diagnostics actions: copy the last action report, dump CG windows, and dump AX windows
- `Hide Menu Bar Icon`, which hides the menu bar icon while keeping gestures running. Restore it with:

  ```bash
  defaults write io.github.stevenalva.MissionSwipe HideStatusBarIcon -bool false; open -a MissionSwipe
  ```

## Desktop safety behavior

When Mission Control is not detected, MissionSwipe does not close anything.

This is intentional. The early desktop close path was useful to prove that AX window closing works, but it is no longer part of the prototype's main product behavior. On the normal desktop:

1. Trackpad scroll gestures run a Mission Control preflight before arming.
2. If the preflight is not strong enough, the gesture is rejected before any close workflow can run.
3. No normal app window should close from desktop scrolling.

## Mission Control behavior

Mission Control integration is experimental. macOS does not expose Mission Control thumbnails as normal app windows through public APIs, so this version focuses on detection and diagnostics first.

When a Mission Control gesture (e.g. swipe-up on a hovered thumbnail) is invoked:

1. MissionSwipe logs the current mouse location.
2. It checks whether Mission Control is likely active using public CGWindowList heuristics, including Dock overlay windows and Mission Control thumbnail-layout evidence.
3. If Mission Control is not likely active, it ignores the request and closes nothing.
4. If Mission Control is likely active and `Enable Mission Control Close` is on, it logs `Mission Control mode active`.
5. It keeps looking for real app windows even if the cursor is over Dock/SystemUIServer overlay windows.
6. It tries to match the cursor to real app windows using current CG bounds and scaled bounds around the active display center.
7. It matches the selected CG candidate back to an AX window.
8. It combines geometry confidence and AX confidence.
9. It closes automatically only if the combined confidence reaches the Mission Control safety threshold.
10. After a successful Mission Control close, it posts a tiny synthetic mouse move to encourage Mission Control to refresh stale hover highlights.

Low or medium confidence Mission Control matches are rejected and logged. Stage Manager can create Dock-owned overlay windows that look similar to Mission Control at first glance, so MissionSwipe now requires Mission Control layout evidence before it arms close/minimize gestures.

## Trackpad gesture behavior

MissionSwipe installs a listen-only public `CGEventTap` for `.scrollWheel` events. If the event tap cannot be installed, it falls back to `NSEvent.addGlobalMonitorForEvents`. It watches trackpad-like scroll events, accumulates vertical and horizontal deltas over a short window, and detects a single vertical swipe intent.

Safety rule: swipe gestures only run while Mission Control is detected. Normal desktop scrolling is ignored.

Gesture mapping:

- Swipe up: close hovered Mission Control thumbnail.
- Swipe down: minimize hovered Mission Control thumbnail. This is experimental and enabled by default for new installs.
- Swipe up on Mission Control blank space: exit Mission Control and arrange visible desktop windows.

Minimize uses the native AX minimize button first. If macOS chooses to play the system minimize animation from Mission Control, MissionSwipe lets that happen. If Mission Control only refreshes the thumbnail layout, that is also accepted behavior. After a successful minimize, MissionSwipe briefly guards the old thumbnail area and suppresses one click on the stale blue hover frame so the window is less likely to restore immediately.

`Arrange Visible Windows` is also available from the menu. Public scroll events do not reliably expose finger count, so MissionSwipe does not bind arrange to a double swipe gesture. Use `Undo Last Arrange` if the layout is not useful.

The detector now performs a Mission Control preflight before it starts accumulating a scroll gesture. If the preflight is not at least medium confidence, the gesture is not armed and the scroll is ignored. This prevents ordinary desktop scrolling, such as scrolling Xcode logs, from reaching the close workflow.

Recent preflight results are reused briefly when the cursor has not moved much. This avoids repeatedly scanning the window list during one scroll burst while still letting a fresh Mission Control gesture arm quickly.

In Mission Control, macOS may only deliver momentum scroll events to a global listener. If the Mission Control preflight passes, MissionSwipe can start tracking from those momentum events while still using cooldown to prevent repeated closes.

With `Debug Logging` off, the detector keeps only the important lifecycle logs: preflight accepted/rejected, trigger, close result, and warnings. Turn `Debug Logging` on when you need raw scroll events and detailed accumulation logs.

The detailed detector diagnostics include:

- `scrollingDeltaY`
- `scrollingDeltaX`
- `hasPreciseScrollingDeltas`
- scroll `phase`
- `momentumPhase`
- accumulated vertical and horizontal deltas
- interpreted direction
- trigger decision

Current gesture constants live in `TrackpadGestureDetector.swift`:

- `invertSwipeDirection = true`
- vertical threshold: `70`
- cooldown: `0.70s`
- rejected preflight cooldown: `0.50s`
- tracking timeout: `0.28s`

The direction is currently inverted because the test machine reports physical two-finger swipe-up as negative `scrollingDeltaY`. If another machine reports the opposite sign, flip `invertSwipeDirection` and test again.

## How to test Mission Control mode

1. Run MissionSwipe from Xcode.
2. Open several normal app windows.
3. On the normal desktop, scroll in Xcode or Chrome and confirm nothing closes.
4. Open Mission Control.
5. Hover over a Mission Control window thumbnail.
6. Swipe up on the trackpad and confirm the hovered thumbnail closes.
7. Confirm one swipe closes at most one window.
8. Confirm `Enable Swipe Down to Minimize` is checked.
9. Open Mission Control, hover over another thumbnail, and swipe down.
10. Confirm the thumbnail minimizes or disappears from the Mission Control layout.
11. Use `Copy Last Action Report` and confirm it matches the closed/minimized app/window.
12. Check the Xcode console logs.

Useful log lines:

- `Mouse location AppKit=..., converted CGWindow=...`
- `Mission Control detection: ...`
- `Mission Control mode active`
- `Best Mission Control geometry match: ...`
- `AX match for CG id=...`
- `Mission Control combined confidence=...`
- `Mission Control close succeeded: ...`
- `Mission Control minimize succeeded: ...`
- `Trackpad swipe-up detected`
- `Trackpad swipe-down detected`
- `Mission Control not active; ignoring close request`
- `Trackpad swipe preflight rejected`
- `Mission Control ranked and thumbnail AX matches disagree`
- `CGWindow: ...` after using `Dump Window List` or when a failure path writes diagnostics
- `Not closing` for rejected low-confidence matches

Useful lines when `Debug Logging` is on:

- `Trackpad scroll event: ...`
- `Trackpad swipe accumulation: ...`
- `Skipping window ...`
- `Keeping candidate ...`

## Debugging steps

- Use `Dump Window List` while Mission Control is open. Inspect owner name, pid, title, bounds, layer, alpha, window number, sharing state, and memory usage.
- Use `Dump AX Windows` while normal app windows are visible. Inspect AX title, position, size, role/subrole, close button availability, and close button actions.
- If Mission Control is not detected, use `Dump Window List` and look for Dock/SystemUIServer overlay entries.
- If Mission Control is detected but no close happens, inspect the geometry candidate scores and the combined confidence.
- If swipe-up does nothing, confirm `Enable Swipe Up to Close` is checked. Turn on `Debug Logging` if you need raw `Trackpad scroll event` lines.
- If swipe-down does nothing, confirm `Enable Swipe Down to Minimize` is checked.
- If swipe logs appear but do not close, search for `Mission Control not active; ignoring close request`.
- If normal desktop scrolling appears to arm the gesture, search for `Trackpad swipe preflight rejected`; normal scrolling should stop there.
- If the wrong swipe direction triggers, flip `invertSwipeDirection` in `TrackpadGestureDetector.swift`.
- If Mission Control closes the wrong window when multiple same-app windows have the same title, inspect `Mission Control ranked AX match` and `ranked and thumbnail AX matches disagree`. The ranked match uses same-PID CG thumbnail order to choose the AX window.
- If AX matching fails, compare CG title/bounds with AX title/position/size.
- If closing fails, inspect the logged close button diagnostics and available AX actions.

## Known limitations

- Public APIs do not provide a stable direct mapping from a Mission Control thumbnail to a real `AXUIElement`.
- Mission Control thumbnail positions may not be present in `CGWindowListCopyWindowInfo`.
- The scaled-bounds mapping is a heuristic and may only produce diagnostic candidates.
- Mission Control can leave a stale blue hover frame after the target thumbnail disappears. MissionSwipe now nudges the mouse by one pixel and back after a successful close to prompt a visual refresh, but the overlay is still controlled by Dock.
- Swipe direction may need inversion depending on natural scrolling and macOS event delivery.
- Trackpad scroll events may behave differently across macOS versions or input devices.
- Gesture close only works while Mission Control is detected.
- Gesture minimize only works while Mission Control is detected and the experimental menu item is enabled.
- A single physical swipe should affect only one window because the detector enters a cooldown after triggering.
- The macOS "magic" minimize effect is controlled by Dock/WindowServer. MissionSwipe presses the native minimize button, but Mission Control may still choose to simply refresh the thumbnail layout.
- Swipe-down minimize briefly installs a stale-thumbnail click guard so one immediate click on the old hover frame is less likely to restore the minimized window.
- If same-app windows have identical titles and nearly identical geometry, AX matching may need the ranked Mission Control order fallback.
- Some apps hide window titles or report different CG and AX geometry.
- Apps may show an unsaved changes confirmation dialog after the close button is pressed.
- Sandboxed or security-sensitive apps may limit AX access.
- Smart Fit cannot force apps below their minimum window size; very-large apps on small screens may overflow even with the adaptive second pass.

## Next milestone

Use the 0.7 logs to keep refining Smart Fit and the Mission Control gesture backend:

- Add a compact in-app diagnostics panel instead of relying only on Xcode console output.
- Make the swipe threshold configurable from the menu.
- Persist a small ring buffer of recent close/minimize attempts for support/debugging.
- Add a lightweight performance counter for Mission Control detections per minute.
- Keep improving same-app, same-title AX matching without re-enabling normal desktop close.
- See [docs/ROADMAP.md](docs/ROADMAP.md) for the Smart Fit optimization ideas (min-size learning, 2D packing, window merging).
