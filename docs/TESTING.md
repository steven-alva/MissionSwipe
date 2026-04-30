# Testing MissionSwipe

## Desktop Safety

1. Launch MissionSwipe.
2. Open Xcode, Chrome, Finder, and at least one chat app.
3. Scroll normally in each app.
4. Press `Control + Option + W` on the desktop.
5. Confirm no normal desktop window closes.

Expected logs:

- `Mission Control detection: isLikelyActive=false`
- `Trackpad swipe preflight rejected`
- `Mission Control not active; ignoring close request`

## Mission Control Close

1. Open several windows.
2. Open Mission Control.
3. Hover a window thumbnail.
4. Swipe up on the trackpad.
5. Confirm only the hovered thumbnail closes.
6. Use `Copy Last Action Report` from the menu.

Expected logs:

- `Swipe gesture preflight accepted`
- `Trackpad swipe-up detected`
- `Mission Control close succeeded`

## Mission Control Minimize

1. Enable `Enable Swipe Down to Minimize (Experimental)`.
2. Open Mission Control.
3. Hover a window thumbnail.
4. Swipe down on the trackpad.
5. Confirm the hovered thumbnail minimizes or disappears from the Mission Control layout.
6. Use `Copy Last Action Report` from the menu.

Expected logs:

- `Swipe gesture preflight accepted`
- `Trackpad swipe-down detected`
- `Pressed AX minimize button successfully`
- `Mission Control minimize succeeded`

## Debug Logs

Keep `Debug Logging` off for normal use. Turn it on only when collecting raw scroll or window matching diagnostics.
